import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';

/// Post-confirm safety regressions: once a confirm may
/// have landed, nothing may report `Failed`; nothing may hang the merchant's
/// future; a crafted return URL cannot swap intents; the idempotency key
/// survives a network change.
void main() {
  const timeout = UqpayTransportException(
    UqpayTransportFailureKind.timeout,
    'no response within 30s',
  );
  const dns = UqpayTransportException(
    UqpayTransportFailureKind.dns,
    'lookup failed',
  );
  const socket = UqpayTransportException(
    UqpayTransportFailureKind.socket,
    'reset',
  );

  /// Drives [clock] until [future] settles.
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

  group('a replay never reports a definitive failure', () {
    test('send #1 times out, the replay fails DNS → reconciled from the '
        'server (Completed), never Failed(dns_failure)', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueError(timeout)
        ..enqueueError(dns)
        ..enqueueHandler(
          (_) async => jsonResponse(200, intentJson(status: 'SUCCEEDED')),
        );
      final result = await settle(
        h.payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(2));
    });

    test('send #1 times out, the replay gets a 400 "already paid" → the poll '
        'reads SUCCEEDED, the pin is not released early', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueError(timeout)
        ..enqueue(
          jsonResponse(400, {
            'code': 'payment_intent_unexpected_state',
            'type': 'invalid_request_error',
            'message': 'intent is not payable',
          }),
        )
        ..enqueueHandler(
          (_) async => jsonResponse(200, intentJson(status: 'SUCCEEDED')),
        );
      final result = await settle(
        h.payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test(
      'guard read failed, confirm rejected 400 → reconcile, not Failed',
      () async {
        final clock = ManualClock();
        final h = PaymentsHarness(clock: clock);
        h.http
          ..enqueueError(socket)
          ..enqueue(
            jsonResponse(400, {
              'code': 'payment_intent_unexpected_state',
              'type': 'invalid_request_error',
              'message': 'intent is not payable',
            }),
          )
          ..enqueueHandler(
            (_) async => jsonResponse(200, intentJson(status: 'SUCCEEDED')),
          );
        final result = await settle(
          h.payments.confirm('pi_123', cardConfirmRequest()),
          clock,
        );
        expect(result, isA<UqpayPaymentCompleted>());
      },
    );

    test('the FIRST send with a good guard read may still be declined '
        'definitively', () async {
      final h = PaymentsHarness();
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(400, {
            'code': 'invalid_payment_method',
            'type': 'invalid_request_error',
            'message': 'invalid billing.email',
          }),
        );
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentFailed>());
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.invalidPaymentMethod,
      );
    });
  });

  group('REQUIRES_PAYMENT_METHOD after a lost confirm', () {
    test('an older declined attempt is not reported as the new confirm '
        'decline; the poll waits for the new attempt', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      final stale = intentJson(attempt: failedAttempt('card_declined'));
      h.http
        ..enqueue(jsonResponse(200, stale))
        ..enqueueError(timeout)
        ..enqueueError(timeout)
        ..enqueueError(timeout)
        ..enqueueError(timeout)
        ..enqueue(jsonResponse(200, stale))
        ..enqueueHandler(
          (_) async => jsonResponse(200, intentJson(status: 'SUCCEEDED')),
        );
      final result = await settle(
        h.payments.confirm('pi_123', cardConfirmRequest()),
        clock,
      );
      expect(result, isA<UqpayPaymentCompleted>());
    });
  });

  group('a hung tokenProvider cannot hang the payment', () {
    test('times out and resolves Failed(authentication_failed) before any '
        'send', () async {
      final clock = ManualClock();
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        tokenProvider: () => Completer<UqpayAuthToken>().future,
      );
      final h = PaymentsHarness(clock: clock, sdk: sdk);
      var settled = false;
      final future = h.payments.confirm('pi_123', cardConfirmRequest());
      unawaited(future.then((_) => settled = true));
      // The timeout is wall-clock (dart:async), so wait a little real time
      // after pumping; the test clock does not drive it.
      // One real 30 s provider timeout on the guard read; the confirm's own
      // token fetch then fails at once from the cooldown.
      final result = await future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw StateError('hung'),
      );
      expect(settled, isTrue);
      expect(result, isA<UqpayPaymentFailed>());
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.authenticationFailed,
      );
      expect(h.confirms, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('the idempotency key survives a network change', () {
    test('a retry from a new IP reuses the key AND the pinned IP', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      // No caller-supplied ip_address: the SDK resolves (and pins) it.
      final request = UqpayConfirmRequest(
        paymentMethod: cardConfirmRequest().paymentMethod,
        browserInfo: browserInfo(),
      );
      final first = UqpayPayments.withDependencies(
        sdk: h.payments.sdk,
        httpClient: h.http,
        clock: clock,
        storage: h.storage,
        deviceIpResolver: () async => '10.0.0.1',
      );
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueError(timeout)
        ..enqueueError(timeout)
        ..enqueueError(timeout)
        ..enqueueError(timeout)
        ..enqueueHandler((_) async => jsonResponse(200, intentJson()));
      final r1 = await settle(
        first.confirm(
          'pi_123',
          request,
          outcomeDeadline: const Duration(seconds: 10),
        ),
        clock,
      );
      // Four timeouts, then the poll shows the confirm never landed: an
      // honest, retryable Failed(timeout) whose pin is kept for the retry.
      expect(r1, isA<UqpayPaymentFailed>());
      expect((r1 as UqpayPaymentFailed).error.isRetryable, isTrue);
      final key1 = h.confirms.first.headers['x-idempotency-key'];
      expect(h.confirms.first.body, contains('"ip_address":"10.0.0.1"'));

      final second = UqpayPayments.withDependencies(
        sdk: h.payments.sdk,
        httpClient: h.http,
        clock: clock,
        storage: h.storage,
        deviceIpResolver: () async => '10.0.0.2',
      );
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final r2 = await settle(second.confirm('pi_123', request), clock);
      expect(r2, isA<UqpayPaymentCompleted>());
      final retry = h.confirms.last;
      expect(retry.headers['x-idempotency-key'], key1, reason: 'same key');
      expect(
        retry.body,
        contains('"ip_address":"10.0.0.1"'),
        reason: 'same bytes: the IP pinned with the key is replayed',
      );
    });
  });

  group('a failed pin write sends nothing', () {
    test('storage write throws → Failed, zero confirms', () async {
      final h = PaymentsHarness();
      final broken = UqpayPayments.withDependencies(
        sdk: h.payments.sdk,
        httpClient: h.http,
        clock: h.clock,
        storage: _ThrowingStore(),
      );
      h.http.enqueue(jsonResponse(200, intentJson()));
      final result = await broken.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentFailed>());
      expect(h.confirms, isEmpty);
    });
  });

  group('server-echoed card numbers are redacted', () {
    test('redactCardLikeDigits handles spaced and dashed PANs', () {
      expect(redactCardLikeDigits('4242 4242 4242 4242'), '[digits]');
      expect(redactCardLikeDigits('4242-4242-4242-4242'), '[digits]');
      expect(redactCardLikeDigits('4242424242424242'), '[digits]');
      expect(
        redactCardLikeDigits('amount 8.98 trace 1a2b3c'),
        'amount 8.98 trace 1a2b3c',
      );
      expect(redactCardLikeDigits('order 20261005123'), 'order 20261005123');
    });

    test('an error envelope message carrying a PAN is cleaned before it '
        'reaches developerMessage / serverMessage', () async {
      final h = PaymentsHarness();
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(400, {
            'code': 'invalid_payment_method',
            'type': 'invalid_request_error',
            'message': 'card 4242 4242 4242 4242 is not supported',
          }),
        );
      final result =
          await h.payments.confirm('pi_123', cardConfirmRequest())
              as UqpayPaymentFailed;
      expect(result.error.developerMessage, isNot(contains('4242 4242')));
      expect(result.error.serverMessage, isNot(contains('4242 4242')));
      expect(result.error.developerMessage, contains('[digits]'));
    });
  });

  group('baseUrlOverride is a bare https origin', () {
    UqpaySdk make(String override) => UqpaySdk.init(
      environment: UqpayEnvironment.sandbox,
      baseUrlOverride: override,
    );
    test('accepts scheme + host (+ port)', () {
      expect(
        make('https://api.example.com').baseUrl,
        'https://api.example.com',
      );
      expect(
        make('https://api.example.com:8443/').baseUrl,
        'https://api.example.com:8443',
      );
    });
    test('rejects credentials, query, fragment and paths', () {
      expect(
        () => make('https://api.uqpay.com@evil.example'),
        throwsArgumentError,
      );
      expect(() => make('https://h.example?x=1'), throwsArgumentError);
      expect(() => make('https://h.example#frag'), throwsArgumentError);
      expect(() => make('https://h.example/v1'), throwsArgumentError);
    });
  });
  group('nothing is sent while paused, replays included', () {
    test('a replay waits for resume; cancelling while paused ends Pending '
        'with no second send', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueueError(timeout)
        ..enqueueHandler(
          (_) async => jsonResponse(200, intentJson(status: 'SUCCEEDED')),
        );
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      final future = flow.confirm();
      await Future<void>.delayed(Duration.zero);
      expect(h.confirms, hasLength(1));
      // Pause during the 3 s replay wait, then let the wait elapse: the
      // replay must NOT be sent until resume.
      flow.pause();
      clock.advance(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(h.confirms, hasLength(1), reason: 'held by pause');
      flow.resume();
      final result = await settle(future, clock);
      expect(h.confirms, hasLength(2), reason: 'replay sent after resume');
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test(
      'cancelled while a replay is held by pause: Pending, one send',
      () async {
        final clock = ManualClock();
        final h = PaymentsHarness(clock: clock);
        h.http
          ..enqueue(jsonResponse(200, intentJson()))
          ..enqueueError(timeout);
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          request: cardConfirmRequest(),
        );
        final future = flow.confirm();
        await Future<void>.delayed(Duration.zero);
        flow.pause();
        clock.advance(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        flow.cancel(UqpayCancelReason.userDismissed);
        final result = await future;
        expect(result, isA<UqpayPaymentPending>());
        expect(h.confirms, hasLength(1));
      },
    );
  });
}

class _ThrowingStore implements KeyValueStore {
  final InMemoryKeyValueStore _inner = InMemoryKeyValueStore();
  @override
  Future<String?> read(String key) => _inner.read(key);
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('disk full');
  @override
  Future<void> remove(String key) => _inner.remove(key);
  @override
  Future<Set<String>> keysWithPrefix(String prefix) =>
      _inner.keysWithPrefix(prefix);
}
