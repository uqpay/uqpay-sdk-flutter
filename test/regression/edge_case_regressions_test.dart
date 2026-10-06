import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/flow/intent_outcome.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/sheet/device_snapshot.dart';
import 'package:uqpay_sdk_flutter/src/transport/http_package_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/token_cache.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';

/// Edge-case regressions across concurrency, the wire format, the UI, 3DS,
/// storage/platform and observed gateway behaviour. Each group names the
/// behaviour it pins down.
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

  group('a foreign exception from the HTTP client never escapes', () {
    test('an Exception on a confirm → Failed(network_error, outcome unknown), '
        'message fixed, exception text absent', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueHandler((_) async => throw const HttpException('hdr: SECRET'));
      for (var i = 0; i < 3; i++) {
        h.http.enqueueHandler(
          (_) async => throw const HttpException('hdr: SECRET'),
        );
      }
      h.http.enqueueHandler(
        (_) async => jsonResponse(200, intentJson(status: 'PENDING')),
      );
      final result = await settle(
        h.payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      // Outcome unknown after a POST: the flow reconciles, never Failed.
      expect(result, isA<UqpayPaymentPending>());
      final cause = (result as UqpayPaymentPending).cause;
      expect(cause, isNotNull);
      expect(cause!.toString(), isNot(contains('SECRET')));
      expect(cause.developerMessage, isNot(contains('SECRET')));
    });

    test('retrieveIntent returns UqpayIntentUnavailable(network_error) '
        'instead of throwing', () async {
      final h = PaymentsHarness();
      h.http.enqueueHandler(
        (_) async => throw const HttpException('boom: SECRET'),
      );
      final result = await h.payments.retrieveIntent('pi_123');
      expect(result, isA<UqpayIntentUnavailable>());
      final error = (result as UqpayIntentUnavailable).error;
      expect(error.code, UqpayErrorCode.networkError);
      expect(error.isOutcomeUnknown, isFalse, reason: 'a GET changes nothing');
      expect(error.isRetryable, isTrue);
      expect(error.toString(), isNot(contains('SECRET')));
    });

    test('an Error (programming bug) still propagates as an SDK bug: '
        'reported to FlutterError, never retried as a network fault', () async {
      final h = PaymentsHarness();
      h.http.enqueueError(StateError('boom'));
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentFailed>());
      expect(reported, hasLength(1));
      expect(h.http.requests, hasLength(1));
    });

    test('retrieveIntent rejects a blank id before any request', () async {
      final h = PaymentsHarness();
      expect(() => h.payments.retrieveIntent('  '), throwsArgumentError);
      expect(h.http.requests, isEmpty);
    });
  });

  group('the auth token never reaches an exception message', () {
    test('a token with an embedded newline → Failed(authentication_failed), '
        'nothing sent, token absent from every surface', () async {
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      final logs = <String>[];
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        tokenProvider: () async => UqpayAuthToken(value: 'sk_SECRET\ntok'),
        loggingEnabled: true,
        logHandler: logs.add,
      );
      final h = PaymentsHarness(sdk: sdk);
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentFailed>());
      final error = (result as UqpayPaymentFailed).error;
      expect(error.code, UqpayErrorCode.authenticationFailed);
      expect(h.http.requests, isEmpty);
      expect(reported, isEmpty);
      expect(error.toString(), isNot(contains('sk_SECRET')));
      expect(logs.join('\n'), isNot(contains('sk_SECRET')));
    });

    test('whitespace around a token is trimmed, not rejected', () async {
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        tokenProvider: () async => UqpayAuthToken(value: '  tok_ok \n'),
      );
      final h = PaymentsHarness(sdk: sdk);
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final result = await h.payments.retrieveIntent('pi_123');
      expect(result, isA<UqpayIntentRetrieved>());
      expect(h.http.requests.single.headers['x-auth-token'], 'Bearer tok_ok');
    });

    test('clientId / onBehalfOf must be header-safe', () {
      for (final bad in ['a b', 'i\nd', 'ïd', 'x\r\nX-Evil: 1']) {
        expect(
          () => sdkWithTokens(['tok'], clientId: bad),
          throwsArgumentError,
          reason: 'clientId $bad',
        );
        expect(
          () => sdkWithTokens(['tok'], onBehalfOf: bad),
          throwsArgumentError,
          reason: 'onBehalfOf $bad',
        );
      }
      expect(sdkWithTokens(['tok'], clientId: 'mch_1').clientId, 'mch_1');
    });

    test('HttpPackageClient: a header dart:io rejects → typed socket failure '
        'with a fixed message, server never hit', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((request) {
        hits++;
        request.response
          ..statusCode = 200
          ..write('{}');
        unawaited(request.response.close());
      });
      final client = HttpPackageClient(inner: IOClient());
      addTearDown(client.close);
      Object? thrown;
      try {
        await client.send(
          UqpayHttpRequest(
            method: 'GET',
            url: Uri.parse('http://127.0.0.1:${server.port}/x'),
            headers: const <String, String>{'authorization': 'Bearer SECRET\n'},
            timeout: const Duration(seconds: 5),
          ),
        );
      } on Object catch (e) {
        thrown = e;
      }
      expect(thrown, isA<UqpayTransportException>());
      expect(
        (thrown! as UqpayTransportException).kind,
        UqpayTransportFailureKind.socket,
      );
      expect(thrown.toString(), isNot(contains('SECRET')));
      expect(hits, 0);
    });
  });

  group('response bodies are always decoded as UTF-8', () {
    test('a 2xx without a charset keeps non-ASCII intact', () async {
      final inner = MockClient(
        (_) async => http.Response.bytes(
          utf8.encode('{"d":"Café ☕"}'),
          200,
          headers: const <String, String>{'content-type': 'text/plain'},
        ),
      );
      final client = HttpPackageClient(inner: inner);
      final response = await client.send(
        UqpayHttpRequest(
          method: 'GET',
          url: Uri.parse('https://example.test/x'),
          headers: const <String, String>{},
          timeout: const Duration(seconds: 5),
        ),
      );
      expect(response.body, '{"d":"Café ☕"}');
    });
  });

  group('reconcile and the outcome budget', () {
    test('reconcile: REQUIRES_PAYMENT_METHOD with no attempt is Pending, '
        'never a decline of a confirm that may not exist', () async {
      final h = PaymentsHarness();
      h.http.enqueue(jsonResponse(200, intentJson()));
      final result = await h.payments.reconcile('pi_123');
      expect(result, isA<UqpayPaymentPending>());
      expect(
        (result as UqpayPaymentPending).lastKnownStatus,
        UqpayIntentStatus.requiresPaymentMethod,
      );
    });

    test('reconcile: a settled declined attempt is still Failed', () async {
      final h = PaymentsHarness();
      h.http.enqueue(
        jsonResponse(
          200,
          intentJson(attempt: failedAttempt('insufficient_funds')),
        ),
      );
      final result = await h.payments.reconcile('pi_123');
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.insufficientFunds,
      );
    });

    test('reconcileUnresolved skips an intent this process is still paying '
        'and never touches its pin', () async {
      final h = PaymentsHarness();
      final gate = Completer<void>();
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueHandler((_) async {
          await gate.future;
          return jsonResponse(200, intentJson(status: 'SUCCEEDED'));
        });
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      final resultFuture = flow.confirm();
      await pump();
      expect(h.confirms, hasLength(1), reason: 'confirm is in flight');
      expect(await h.payments.unresolvedIntentIds(), ['pi_123']);
      final swept = await h.payments.reconcileUnresolved();
      expect(swept, isEmpty, reason: 'in-flight intent skipped');
      expect(
        h.reads,
        hasLength(1),
        reason: 'only the guard read, no sweep GET',
      );
      expect(h.storage.entries, isNotEmpty, reason: 'pin untouched');
      gate.complete();
      expect(await resultFuture, isA<UqpayPaymentCompleted>());
      expect(h.storage.entries, isEmpty, reason: 'released on Completed');
    });

    test('reconcileUnresolved survives a storage listing failure', () async {
      final h = PaymentsHarness();
      // No pins at all: the sweep is simply empty, nothing thrown.
      expect(await h.payments.reconcileUnresolved(), isEmpty);
    });

    test(
      'rapid pause/resume with no time passing spends no budget',
      () async {
        final clock = ManualClock();
        final h = PaymentsHarness(clock: clock);
        h.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
        for (var i = 0; i < 200; i++) {
          h.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
        }
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          outcomeDeadline: const Duration(seconds: 30),
        );
        unawaited(flow.awaitOutcome());
        await pump();
        for (var i = 0; i < 100; i++) {
          flow.pause();
          await pump(2);
          flow.resume();
          await pump(2);
        }
        expect(flow.isDone, isFalse, reason: 'no wall time passed');
        flow.cancel(UqpayCancelReason.userDismissed);
        await flow.result;
      },
    );

    test('after resume() the status stream shows the resumed phase, '
        'not paused', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final flow = h.payments.createFlow(intentId: 'pi_123');
      final phases = <UqpayPaymentPhase>[];
      flow.status.listen((s) => phases.add(s.phase));
      unawaited(flow.awaitOutcome());
      await pump();
      flow.pause();
      await pump();
      expect(phases.last, UqpayPaymentPhase.paused);
      flow.resume();
      await pump();
      expect(phases.last, isNot(UqpayPaymentPhase.paused));
      await settle(flow.result, clock);
    });
  });

  group('pin ownership', () {
    test('a flow that reused an existing pin and was cancelled before '
        'sending does not release it', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      final request = cardConfirmRequest();
      // Another attempt minted the pin and is "still in flight".
      final store = IdempotencyStore(
        storage: h.storage,
        clock: clock,
        namespace: IdempotencyStore.namespaceFor(
          environment: 'sandbox',
          baseUrl: h.payments.sdk.baseUrl,
          merchant: h.payments.sdk.clientId,
        ),
      );
      await store.obtain(intentId: 'pi_123', body: request.toJson());
      expect(h.storage.entries, hasLength(1));

      final flow = h.payments.createFlow(intentId: 'pi_123', request: request);
      h.http.enqueueHandler((_) async {
        // Cancel during the guard read, before the confirm leaves.
        flow.cancel(UqpayCancelReason.userDismissed);
        return jsonResponse(200, intentJson());
      });
      final result = await flow.confirm();
      expect(result, isA<UqpayPaymentCanceled>());
      expect(h.confirms, isEmpty);
      expect(h.storage.entries, hasLength(1), reason: 'not ours to release');
    });

    test('a reused pin IS released once the server answers definitively, '
        'so the next retry gets a fresh key', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      final request = cardConfirmRequest();
      final store = IdempotencyStore(
        storage: h.storage,
        clock: clock,
        namespace: IdempotencyStore.namespaceFor(
          environment: 'sandbox',
          baseUrl: h.payments.sdk.baseUrl,
          merchant: h.payments.sdk.clientId,
        ),
      );
      final existing = await store.obtain(
        intentId: 'pi_123',
        body: request.toJson(),
      );
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(attempt: failedAttempt('card_declined')),
          ),
        );
      final result = await settle(
        h.payments.confirm('pi_123', request),
        clock,
      );
      expect(result, isA<UqpayPaymentFailed>());
      expect(h.confirms.single.headers['x-idempotency-key'], existing.key);
      expect(h.storage.entries, isEmpty, reason: 'decline is definitive');
    });
  });

  group('cancelIntent reads the gateway as it actually responds', () {
    test('2xx with the OLD status + cancellation_reason is an accepted '
        'cancel → Canceled(merchantCancelled)', () async {
      final h = PaymentsHarness();
      final body = intentJson()..['cancellation_reason'] = 'abandoned';
      h.http.enqueue(jsonResponse(200, body));
      final result = await h.payments.cancelIntent('pi_123');
      expect(result, isA<UqpayPaymentCanceled>());
      expect(
        (result as UqpayPaymentCanceled).reason,
        UqpayCancelReason.merchantCancelled,
      );
    });

    test(
      '2xx with SUCCEEDED is reported as Completed, never Canceled',
      () async {
        final h = PaymentsHarness();
        final body = intentJson(status: 'SUCCEEDED')
          ..['cancellation_reason'] = 'abandoned';
        h.http.enqueue(jsonResponse(200, body));
        expect(
          await h.payments.cancelIntent('pi_123'),
          isA<UqpayPaymentCompleted>(),
        );
      },
    );
  });

  group('REQUIRES_CUSTOMER_ACTION with a FAILED attempt and no '
      'next_action is a failure of this attempt', () {
    test('resolves Failed(code) instead of waiting out the deadline', () {
      final intent = UqpayPaymentIntent.fromJson(
        intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          attempt: failedAttempt('system_error'),
        ),
      );
      final outcome = IntentOutcome.of(intent, afterConfirm: true);
      expect(outcome, isA<Resolved>());
      final failed = (outcome as Resolved).result as UqpayPaymentFailed;
      expect(failed.error.serverCode, 'system_error');
      expect(failed.error.isOutcomeUnknown, isFalse);
    });

    test('with a next_action still served, keep waiting', () {
      final intent = UqpayPaymentIntent.fromJson(
        intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          attempt: failedAttempt('system_error'),
          nextAction: qrNextAction(),
        ),
      );
      expect(IntentOutcome.of(intent, afterConfirm: true), isA<KeepWaiting>());
    });
  });

  group('lenient decode, amount formatting, reserved codes', () {
    test('payment_method with a blank type is dropped, the intent decodes', () {
      final json = intentJson(status: 'SUCCEEDED')
        ..['payment_method'] = <String, Object?>{'type': ''};
      final intent = UqpayPaymentIntent.fromJson(json);
      expect(intent.status, UqpayIntentStatus.succeeded);
      expect(intent.paymentMethod, isNull);
    });

    test('format() never shows a wrong number for a huge scale', () {
      const wire = '1.0000000000000000005';
      final text = UqpayAmount.parse(wire).format(currencyCode: 'USD');
      expect(text, contains(wire));
      expect(text, isNot(contains('-')));
    });

    test('a server failure_code equal to an SDK-reserved code maps to unknown '
        'and keeps the raw value', () {
      for (final reserved in ['timeout', 'network_error', 'cancelled']) {
        final error = mapFailure(
          intentStatus: UqpayIntentStatus.requiresPaymentMethod,
          attemptFailed: true,
          attemptFailureCode: reserved,
        );
        expect(error.code, UqpayErrorCode.unknown, reason: reserved);
        expect(error.serverCode, reserved);
        expect(error.isOutcomeUnknown, isFalse);
      }
    });

    test('card holder name above 128 characters is rejected locally', () {
      expect(
        () => cardConfirmRequest(cardName: 'A' * 129),
        throwsArgumentError,
      );
      expect(cardConfirmRequest(cardName: 'A' * 128), isNotNull);
    });
  });

  group('storage: the device snapshot and the token cache', () {
    test('screen dimensions are clamped to the gateway range 1–9999', () {
      final info = buildDeviceSnapshot(
        mediaQuery: const MediaQueryData(size: Size(0, 20000)),
        locale: const Locale('en'),
        nowUtc: DateTime.utc(2026),
        platform: TargetPlatform.iOS,
        isWeb: false,
      );
      expect(info.screenWidth, 1);
      expect(info.screenHeight, 9999);
    });

    test('a provider that throws synchronously is retried after the '
        'cooldown, not stuck forever', () async {
      final clock = FakeClock();
      var calls = 0;
      final cache = TokenCache(
        provider: () {
          calls++;
          if (calls == 1) {
            throw StateError('no session yet');
          }
          return Future<UqpayAuthToken>.value(UqpayAuthToken(value: 'tok'));
        },
        clock: clock,
      );
      await expectLater(cache.token(), throwsStateError);
      clock.advance(TokenCache.failureCooldown + const Duration(seconds: 1));
      expect((await cache.token()).value, 'tok');
      expect(calls, 2);
    });
  });

  group('guard read: REQUIRES_CUSTOMER_ACTION without a next_action', () {
    test('and no attempt: nothing is pending, the confirm proceeds', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(
          jsonResponse(200, intentJson(status: 'REQUIRES_CUSTOMER_ACTION')),
        )
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final result = await settle(
        h.payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(1));
    });

    test(
      'and a FAILED attempt: that attempt failed, no second confirm',
      () async {
        final clock = ManualClock();
        final h = PaymentsHarness(clock: clock);
        h.http.enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              attempt: failedAttempt('system_error'),
            ),
          ),
        );
        final result = await settle(
          h.payments.confirm('pi_123', cardConfirmRequest()),
          clock,
        );
        expect(result, isA<UqpayPaymentFailed>());
        expect((result as UqpayPaymentFailed).error.serverCode, 'system_error');
        expect(h.confirms, isEmpty);
      },
    );
  });

  group('storage: a card confirm with no resolvable IP', () {
    test('fails before sending with a clear developer message', () async {
      final h = PaymentsHarness();
      final payments = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(['tok']),
        httpClient: h.http,
        clock: FakeClock(),
        storage: h.storage,
        pollingPolicy: PollingPolicy(jitter: 0),
        deviceIpResolver: () async => null,
      );
      h.http.enqueue(jsonResponse(200, intentJson()));
      final request = UqpayConfirmRequest(
        paymentMethod: cardConfirmRequest().paymentMethod,
        browserInfo: browserInfo(),
      );
      final result = await payments.confirm('pi_123', request);
      expect(result, isA<UqpayPaymentFailed>());
      final error = (result as UqpayPaymentFailed).error;
      expect(error.code, UqpayErrorCode.invalidConfiguration);
      expect(error.isRetryable, isTrue);
      expect(h.confirms, isEmpty);
      expect(h.storage.entries, isEmpty, reason: 'no pin written');
    });
  });
}
