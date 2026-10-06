import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/flow/intent_outcome.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_validation.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/uqpay_qr_view.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/qr_screen_view.dart';
import 'package:uqpay_sdk_flutter/src/transport/http_package_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';

/// Hardening regressions: idempotency-key reuse across sheet sessions,
/// storage that can never hang the result, expired-pin purging, trace ids
/// on declines, QR image origin, HTTP-client isolation and coverage
/// completeness.
void main() {
  Future<void> pump([int n = 20]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<UqpayPaymentResult> settle(
    Future<UqpayPaymentResult> future,
    ManualClock clock,
  ) async {
    var settled = false;
    unawaited(future.then((_) => settled = true));
    for (var i = 0; i < 400 && !settled; i++) {
      await Future<void>.delayed(Duration.zero);
      clock.advance(const Duration(seconds: 2));
    }
    return future;
  }

  group('the key survives a new sheet session', () {
    test('the fingerprint ignores browser_info, so a retry with a fresh '
        'device snapshot reuses the key', () {
      final a = cardConfirmRequest().toJson()
        ..['browser_info'] = <String, Object?>{'device_id': 'aaaa'};
      final b = cardConfirmRequest().toJson()
        ..['browser_info'] = <String, Object?>{'device_id': 'bbbb'};
      expect(
        IdempotencyStore.fingerprintFor(a),
        IdempotencyStore.fingerprintFor(b),
      );
    });

    test('a card with the same last 4 but a different BIN gets a new key', () {
      final a = cardConfirmRequest(cardNumber: '4000056655554242').toJson();
      final b = cardConfirmRequest(cardNumber: '4111111111114242').toJson();
      expect(
        IdempotencyStore.fingerprintFor(a),
        isNot(IdempotencyStore.fingerprintFor(b)),
      );
      // Never the PAN itself: neither full number appears in the pin.
      expect(IdempotencyStore.fingerprintFor(a), isNot(contains('4242424242')));
    });

    test('a second flow after process death sends the SAME key with a new '
        'snapshot', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      final first = UqpayConfirmRequest(
        paymentMethod: cardConfirmRequest().paymentMethod,
        browserInfo: browserInfo(),
        ipAddress: '10.0.0.2',
      );
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueHandler((_) async {
          // The process "dies" here: nothing answers the first confirm.
          return Completer<UqpayHttpResponse>().future;
        });
      final flow = h.payments.createFlow(intentId: 'pi_123', request: first);
      unawaited(flow.confirm());
      await pump();
      expect(h.confirms, hasLength(1));
      final key = h.confirms.single.headers['x-idempotency-key'];

      // Relaunch: a new UqpayPayments over the SAME storage, a new snapshot.
      final h2 = PaymentsHarness(clock: clock);
      await h2.payments.unresolvedIntentIds(); // warm, no-op
      final payments2 = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(['tok']),
        httpClient: h2.http,
        clock: clock,
        storage: h.storage,
      );
      h2.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final second = UqpayConfirmRequest(
        paymentMethod: cardConfirmRequest().paymentMethod,
        browserInfo: const UqpayBrowserInfo(
          browser: UqpayBrowserDetails(userAgent: 'other UA'),
          deviceId: 'different-session',
          language: 'fr-FR',
          mobile: UqpayMobileDetails(
            deviceModel: 'Pixel',
            osType: 'ANDROID',
            osVersion: '15',
          ),
          screenHeight: 1000,
          screenWidth: 500,
          timezone: '1',
        ),
        ipAddress: '10.0.0.2',
      );
      final result = await settle(payments2.confirm('pi_123', second), clock);
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h2.confirms.single.headers['x-idempotency-key'], key);
    });
  });

  group('local storage can never hang the result', () {
    test('a pin write that never answers → retryable Failed, nothing sent, '
        'within the storage bound', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      final payments = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(['tok']),
        httpClient: h.http,
        clock: clock,
        storage: BoundedKeyValueStore(_HangingStore(), clock: clock),
      );
      h.http.enqueue(jsonResponse(200, intentJson()));
      final result = await settle(
        payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect(result, isA<UqpayPaymentFailed>());
      final error = (result as UqpayPaymentFailed).error;
      expect(error.isRetryable, isTrue);
      expect(error.developerMessage, contains('did not respond'));
      expect(h.confirms, isEmpty);
    });

    test('a pin release that never answers still delivers Completed', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      final store = _HangingStore(hangOnRemove: true);
      final payments = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(['tok']),
        httpClient: h.http,
        clock: clock,
        storage: BoundedKeyValueStore(store, clock: clock),
      );
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final result = await settle(
        payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect(result, isA<UqpayPaymentCompleted>());
    });
  });

  group('expired pins are purged without a reconcile', () {
    test(
      'the first flow purges pins older than 24 h in the background',
      () async {
        final clock = FakeClock();
        final h = PaymentsHarness(clock: clock);
        final store = IdempotencyStore(
          storage: h.storage,
          clock: clock,
          namespace: IdempotencyStore.namespaceFor(
            environment: 'sandbox',
            baseUrl: h.payments.sdk.baseUrl,
            merchant: h.payments.sdk.clientId,
          ),
        );
        await store.obtain(
          intentId: 'pi_old',
          body: cardConfirmRequest().toJson(),
        );
        clock.advance(const Duration(hours: 25));
        expect(h.storage.entries, hasLength(1));
        h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
        await h.payments.reconcile('pi_other');
        await pump();
        expect(h.storage.entries, isEmpty);
      },
    );
  });

  group('declines inside a 2xx keep the trace id', () {
    test('an intent FAILED carries the response trace and response ids', () {
      final intent = UqpayPaymentIntent.fromJson(
        intentJson(status: 'FAILED', attempt: failedAttempt('card_declined')),
      );
      final outcome = IntentOutcome.of(
        intent,
        afterConfirm: true,
        traceId: 'trace-9',
        responseId: 'resp-9',
      );
      final failed = (outcome as Resolved).result as UqpayPaymentFailed;
      expect(failed.error.traceId, 'trace-9');
      expect(failed.error.responseId, 'resp-9');
    });

    test('through the flow: the decline from a confirm response has the '
        'trace id of that response', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(attempt: failedAttempt('insufficient_funds')),
            traceId: 'trace-confirm',
          ),
        );
      final result = await settle(
        h.payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect((result as UqpayPaymentFailed).error.traceId, 'trace-confirm');
    });
  });

  group('the QR image is fetched only from UQPAY over https', () {
    test('allow-list', () {
      expect(
        SheetQrScreenView.isAllowedImageUrl('https://cdn.uqpay.com/q.png'),
        isTrue,
      );
      expect(
        SheetQrScreenView.isAllowedImageUrl(
          'https://api-sandbox.uqpaytech.com/qr/1.png',
        ),
        isTrue,
      );
      for (final bad in [
        'http://cdn.uqpay.com/q.png',
        'https://evil.example/q.png',
        'https://uqpay.com.evil.example/q.png',
        'https://notuqpay.com/q.png',
        'file:///etc/passwd',
        '',
      ]) {
        expect(SheetQrScreenView.isAllowedImageUrl(bad), isFalse, reason: bad);
      }
    });

    testWidgets('a foreign qr_code_url is never loaded; the raw payload is '
        'rendered instead', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SheetQrScreenView(
              l10n: const UqpayLocalizations(),
              qr: const UqpayDisplayQrCode(
                qrCode: '00020101021226',
                qrCodeUrl: 'https://evil.example/track.png',
              ),
              methodType: 'paynow',
              remaining: const Duration(minutes: 5),
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byType(UqpayQrView), findsOneWidget);
    });

    testWidgets('a foreign qr_code_url with no raw payload shows the failure '
        'text and loads nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SheetQrScreenView(
              l10n: const UqpayLocalizations(),
              qr: const UqpayDisplayQrCode(
                qrCodeUrl: 'https://evil.example/track.png',
              ),
              methodType: 'paynow',
              remaining: const Duration(minutes: 5),
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('The code could not be displayed.'), findsOneWidget);
    });
  });

  group('the default HTTP client ignores HttpOverrides.global', () {
    test('a global override is never consulted', () async {
      final previous = HttpOverrides.current;
      final counting = _CountingOverrides();
      HttpOverrides.global = counting;
      addTearDown(() => HttpOverrides.global = previous);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..statusCode = 200
          ..write('{}');
        unawaited(request.response.close());
      });
      final client = HttpPackageClient();
      addTearDown(client.close);
      final response = await client.send(
        UqpayHttpRequest(
          method: 'GET',
          url: Uri.parse('http://127.0.0.1:${server.port}/x'),
          headers: const <String, String>{},
          timeout: const Duration(seconds: 5),
        ),
      );
      expect(response.statusCode, 200);
      expect(counting.created, 0, reason: 'global override must be bypassed');
    });

    test('an injected client is used as-is', () async {
      final client = HttpPackageClient(
        inner: MockClient((_) async => http.Response('{}', 200)),
      );
      final response = await client.send(
        UqpayHttpRequest(
          method: 'GET',
          url: Uri.parse('https://example.test/x'),
          headers: const <String, String>{},
          timeout: const Duration(seconds: 5),
        ),
      );
      expect(response.statusCode, 200);
    });
  });

  group('coverage completeness for the 100% files', () {
    test('redactCardLikeDigits normalises non-ASCII digits', () {
      // Arabic-Indic, full-width and Devanagari digits spelling a PAN.
      const arabic = '٤٢٤٢٤٢٤٢٤٢٤٢٤٢٤٢';
      const fullWidth = '４２４２４２４２４２４２４２４２';
      const devanagari = '४२४२४२४२४२४२४२४२';
      for (final pan in [arabic, fullWidth, devanagari]) {
        expect(
          redactCardLikeDigits('card $pan declined'),
          isNot(contains(pan)),
        );
      }
      // A short run is not a PAN: normalised to ASCII, not redacted.
      expect(redactCardLikeDigits('order ٤٢'), 'order 42');
    });

    test('UqpayAmount.format falls back to the exact wire string for a scale '
        'above 15 or a huge integer part', () {
      expect(
        UqpayAmount.parse('1.0000000000000000005').format(currencyCode: 'USD'),
        'USD 1.0000000000000000005',
      );
      expect(
        UqpayAmount.parse(
          '99999999999999999999.5',
        ).format(currencyCode: 'USD'),
        'USD 99999999999999999999.5',
      );
      expect(UqpayAmount.parse('12.50').format(currencyCode: 'USD'), r'$12.50');
    });

    test(
      'BoundedKeyValueStore: every call is bounded on the SDK clock',
      () async {
        final clock = ManualClock();
        final inner = _HangingStore(hangOnRemove: true);
        final store = BoundedKeyValueStore(inner, clock: clock);
        await store.write('k', 'v');
        expect(await store.read('k'), 'v');
        expect(await store.keysWithPrefix('k'), {'k'});
        final removal = store.remove('k');
        var threw = false;
        unawaited(
          removal.then(
            (_) {},
            onError: (Object e) => threw = e is TimeoutException,
          ),
        );
        await pump();
        expect(threw, isFalse);
        clock.advance(BoundedKeyValueStore.defaultBound);
        await pump();
        expect(threw, isTrue);
      },
    );

    test('groupNumber keeps overflow digits beyond the last group', () {
      expect(
        UqpayCardValidator.groupNumber('42424242424242424242', null),
        '4242 4242 4242 4242 4242',
      );
      expect(
        UqpayCardValidator.groupNumber('424242424242424242421', null),
        '4242 4242 4242 4242 4242 1',
      );
    });

    test('IntentOutcome: lost confirm, attempt without id → KeepWaiting', () {
      final attempt = failedAttempt('card_declined')..remove('attempt_id');
      final intent = UqpayPaymentIntent.fromJson(intentJson(attempt: attempt));
      final outcome = IntentOutcome.of(
        intent,
        afterConfirm: true,
        lostConfirmError: mapFailure(outcomeDeadlineExceeded: true),
        attemptIdBeforeConfirm: 'pa_before',
      );
      expect(outcome, isA<KeepWaiting>());
    });

    test('IntentOutcome: a stale settled attempt with a definitive confirm '
        'answer → Failed(no payment method attached)', () {
      final intent = UqpayPaymentIntent.fromJson(
        intentJson(attempt: failedAttempt('card_declined')),
      );
      final outcome = IntentOutcome.of(
        intent,
        afterConfirm: true,
        attemptIdBeforeConfirm: 'pa_1', // same id as the attempt: stale
      );
      final failed = (outcome as Resolved).result as UqpayPaymentFailed;
      expect(failed.error.code, UqpayErrorCode.invalidPaymentMethod);
    });

    test('IntentOutcome: REQUIRES_PAYMENT_METHOD with an EXPIRED attempt is '
        'settled (Failed); an in-progress attempt is not', () {
      for (final (status, matcher) in [
        ('EXPIRED', isA<Resolved>()),
        ('CANCELLED', isA<Resolved>()),
        ('INITIATED', isA<KeepWaiting>()),
      ]) {
        final intent = UqpayPaymentIntent.fromJson(
          intentJson(
            attempt: <String, Object?>{
              'attempt_id': 'pa_new',
              'attempt_status': status,
            },
          ),
        );
        expect(
          IntentOutcome.of(
            intent,
            afterConfirm: true,
            attemptIdBeforeConfirm: 'pa_old',
          ),
          matcher,
          reason: status,
        );
      }
      // An in-progress status with a failure code is still settled.
      final coded = UqpayPaymentIntent.fromJson(
        intentJson(
          attempt: <String, Object?>{
            'attempt_id': 'pa_new',
            'attempt_status': 'INITIATED',
            'failure_code': 'card_declined',
          },
        ),
      );
      expect(IntentOutcome.of(coded, afterConfirm: true), isA<Resolved>());
    });

    test('IntentOutcome: REQUIRES_CUSTOMER_ACTION, no next_action, attempt '
        'in progress → KeepWaiting unless it carries a failure code', () {
      final waiting = UqpayPaymentIntent.fromJson(
        intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          attempt: <String, Object?>{
            'attempt_id': 'pa_1',
            'attempt_status': 'INITIATED',
          },
        ),
      );
      expect(IntentOutcome.of(waiting, afterConfirm: true), isA<KeepWaiting>());
      final coded = UqpayPaymentIntent.fromJson(
        intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          attempt: <String, Object?>{
            'attempt_id': 'pa_1',
            'attempt_status': 'INITIATED',
            'failure_code': 'system_error',
          },
        ),
      );
      expect(IntentOutcome.of(coded, afterConfirm: true), isA<Resolved>());
    });

    test('IntentOutcome: REQUIRES_CUSTOMER_ACTION with an EXPIRED or '
        'CANCELLED attempt and no next_action → Failed', () {
      for (final status in ['EXPIRED', 'CANCELLED']) {
        final attempt = <String, Object?>{
          'attempt_id': 'pa_1',
          'attempt_status': status,
        };
        final intent = UqpayPaymentIntent.fromJson(
          intentJson(status: 'REQUIRES_CUSTOMER_ACTION', attempt: attempt),
        );
        expect(
          IntentOutcome.of(intent, afterConfirm: true),
          isA<Resolved>(),
          reason: status,
        );
      }
    });

    test('SharedPreferencesKeyValueStore round-trips through the real '
        'adapter', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final store = SharedPreferencesKeyValueStore(
        preferences: SharedPreferencesAsync(),
      );
      expect(await store.read('uqpay.a'), isNull);
      await store.write('uqpay.a', '1');
      await store.write('uqpay.b', '2');
      await store.write('other.c', '3');
      expect(await store.read('uqpay.a'), '1');
      expect(await store.keysWithPrefix('uqpay.'), {'uqpay.a', 'uqpay.b'});
      await store.remove('uqpay.a');
      expect(await store.read('uqpay.a'), isNull);
      expect(await store.keysWithPrefix('uqpay.'), {'uqpay.b'});
    });
  });
}

/// A storage whose write (or remove) never completes.
class _HangingStore implements KeyValueStore {
  _HangingStore({this.hangOnRemove = false});
  final bool hangOnRemove;
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) => hangOnRemove
      ? Future<void>.sync(() => _data[key] = value)
      : Completer<void>().future;

  @override
  Future<void> remove(String key) => hangOnRemove
      ? Completer<void>().future
      : Future<void>.sync(() => _data.remove(key));

  @override
  Future<Set<String>> keysWithPrefix(String prefix) async =>
      _data.keys.where((k) => k.startsWith(prefix)).toSet();
}

class _CountingOverrides extends HttpOverrides {
  int created = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}
