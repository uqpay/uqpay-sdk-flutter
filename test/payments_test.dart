import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_api_client.dart';

import 'support/fakes.dart';

/// The `UqpayPayments` facade: retrieveIntent, reconcile, cancelIntent,
/// unresolved-pin bookkeeping and the SDK handle wiring.
void main() {
  late PaymentsHarness h;

  setUp(() {
    h = PaymentsHarness();
  });

  group('retrieveIntent', () {
    test('returns the intent on 200', () async {
      h.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
      final result = await h.payments.retrieveIntent('pi_123');
      expect(result, isA<UqpayIntentRetrieved>());
      final intent = (result as UqpayIntentRetrieved).intent;
      expect(intent.id, 'pi_123');
      expect(intent.status, UqpayIntentStatus.pending);
      expect(intent.availablePaymentMethodTypes, ['card', 'paynow']);
      expect(h.reads.single.method, 'GET');
    });

    test('returns Unavailable, never throws, on 404 / transport', () async {
      h.http
        ..enqueue(
          jsonResponse(404, <String, Object?>{
            'code': 'resource_not_found',
            'message': 'no such intent',
          }),
        )
        ..enqueueError(
          const UqpayTransportException(UqpayTransportFailureKind.dns, 'dns'),
        );
      final notFound = await h.payments.retrieveIntent('pi_missing');
      expect(notFound, isA<UqpayIntentUnavailable>());
      expect((notFound as UqpayIntentUnavailable).error.httpStatus, 404);
      expect(notFound.error.serverCode, 'resource_not_found');

      final offline = await h.payments.retrieveIntent('pi_123');
      expect(
        (offline as UqpayIntentUnavailable).error.code,
        UqpayErrorCode.dnsFailure,
      );
      expect(offline.toString(), contains('dns_failure'));
    });

    test('an empty id throws ArgumentError before sending', () {
      expect(() => h.payments.retrieveIntent(''), throwsArgumentError);
      expect(h.http.requests, isEmpty);
    });
  });

  group('reconcile', () {
    test('terminal intent → the terminal result', () async {
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final result = await h.payments.reconcile('pi_123');
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.reads, hasLength(1));
    });

    test('in-flight intent → Pending that can reconcile again', () async {
      h.http
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueue(jsonResponse(200, intentJson(status: 'REQUIRES_CAPTURE')));
      final first = await h.payments.reconcile('pi_123');
      expect(first, isA<UqpayPaymentPending>());
      final pending = first as UqpayPaymentPending;
      expect(pending.lastKnownStatus, UqpayIntentStatus.pending);
      expect(pending.intent?.id, 'pi_123');
      expect(pending.cause, isNull);
      expect(pending.toString(), contains('PENDING'));

      final second = await pending.reconcile();
      expect(second, isA<UqpayPaymentCompleted>());
      expect(h.reads, hasLength(2));
    });

    test('a failed read → Pending with the cause, status unknown', () async {
      h.http.enqueue(jsonResponse(503, 'down'));
      final result = await h.payments.reconcile('pi_123');
      final pending = result as UqpayPaymentPending;
      expect(pending.lastKnownStatus, isNull);
      expect(pending.intent, isNull);
      expect(pending.cause?.code, UqpayErrorCode.serverError);
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      expect(await pending.reconcile(), isA<UqpayPaymentCompleted>());
    });

    test('a declined attempt → Failed via the shared mapper', () async {
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

    test('a Pending from a flow reconciles through the same path', () async {
      // Cancel mid-confirm to obtain a Pending, then reconcile it.
      h.http.enqueue(jsonResponse(200, intentJson()));
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      h.http.enqueueHandler((_) async {
        flow.cancel(UqpayCancelReason.userDismissed);
        return jsonResponse(200, intentJson(status: 'PENDING'));
      });
      final pending = await flow.confirm() as UqpayPaymentPending;
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      expect(await pending.reconcile(), isA<UqpayPaymentCompleted>());
    });
  });

  group('cancelIntent', () {
    test('POSTs /cancel with the reason and returns Canceled', () async {
      h.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'CANCELLED')
            ..['cancellation_reason'] = 'requested_by_customer',
        ),
      );
      final result = await h.payments.cancelIntent('pi_123');
      expect(result, isA<UqpayPaymentCanceled>());
      final canceled = result as UqpayPaymentCanceled;
      expect(canceled.reason, UqpayCancelReason.merchantCancelled);
      expect(canceled.intent?.cancellationReason, 'requested_by_customer');
      final request = h.http.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v2/payment_intents/pi_123/cancel');
      expect(request.body, '{"cancellation_reason":"requested_by_customer"}');
      expect(
        request.headers['x-idempotency-key'],
        matches(RegExp(r'^[0-9a-f-]{36}$')),
      );
    });

    test('a custom reason is sent verbatim', () async {
      h.http.enqueue(jsonResponse(200, intentJson(status: 'CANCELLED')));
      await h.payments.cancelIntent('pi_123', cancellationReason: 'abandoned');
      expect(
        h.http.requests.single.body,
        '{"cancellation_reason":"abandoned"}',
      );
    });

    test('a refused cancel → Failed with the server error, no retry', () async {
      h.http.enqueue(
        jsonResponse(400, <String, Object?>{
          'code': 'invalid_request',
          'message': 'intent already succeeded',
        }),
      );
      final result = await h.payments.cancelIntent('pi_123');
      final failed = result as UqpayPaymentFailed;
      expect(failed.error.httpStatus, 400);
      expect(failed.error.serverCode, 'invalid_request');
      expect(h.http.requests, hasLength(1));
    });

    test('a 2xx that is not cancelled reports the intent as it is', () async {
      h.http
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
      expect(
        await h.payments.cancelIntent('pi_123'),
        isA<UqpayPaymentCompleted>(),
      );
      final pending =
          await h.payments.cancelIntent('pi_123') as UqpayPaymentPending;
      h.http.enqueue(jsonResponse(200, intentJson(status: 'CANCELLED')));
      expect(await pending.reconcile(), isA<UqpayPaymentCanceled>());
    });

    test('argument validation throws before sending', () {
      expect(
        () => h.payments.cancelIntent('pi_1', cancellationReason: ' '),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'cancellationReason',
          ),
        ),
      );
      expect(() => h.payments.cancelIntent(''), throwsArgumentError);
      expect(h.http.requests, isEmpty);
      // The transport-level guard on the key, for completeness.
      expect(
        () =>
            UqpayApiClient(
              sdk: sdkWithTokens(['t']),
              httpClient: h.http,
              clock: h.clock,
            ).cancelPaymentIntent(
              id: 'pi_1',
              cancellationReason: 'abandoned',
              idempotencyKey: '',
            ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'idempotencyKey'),
        ),
      );
    });

    test("a server cancel releases the intent's pins", () async {
      // Leave a pin behind with a lost confirm.
      h.http.enqueue(jsonResponse(200, intentJson()));
      for (var i = 0; i < 4; i++) {
        h.http.enqueueError(
          const UqpayTransportException(
            UqpayTransportFailureKind.timeout,
            'x',
          ),
        );
      }
      h.http.enqueue(jsonResponse(200, intentJson()));
      await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(await h.payments.unresolvedIntentIds(), ['pi_123']);

      h.http.enqueue(jsonResponse(200, intentJson(status: 'CANCELLED')));
      await h.payments.cancelIntent('pi_123');
      expect(await h.payments.unresolvedIntentIds(), isEmpty);
    });
  });

  group('SDK handle wiring', () {
    test('sdk.payments builds production dependencies without I/O', () {
      final sdk = sdkWithTokens(['t']);
      final payments = sdk.payments;
      expect(payments.sdk, same(sdk));
      expect(identical(sdk.payments, payments), isTrue);
      payments
        ..close()
        ..close(); // idempotent
    });

    test('result and status value types print safely', () async {
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      final events = <UqpayPaymentStatus>[];
      flow.status.listen(events.add);
      final result = await flow.confirm();
      expect(
        result.toString(),
        'UqpayPaymentCompleted(intentId: pi_123, '
        'status: SUCCEEDED)',
      );
      expect(events.first.toString(), contains('phase: preparing'));
      expect(events.first, events.first);
      expect(events.first.hashCode, events.first.hashCode);
      expect(events.first, isNot(events.last));
      expect(UqpayPaymentPhase.fromRaw('later_phase').isUnknown, isTrue);
      expect(UqpayPaymentPhase.confirming.isUnknown, isFalse);
      expect(UqpayPaymentPhase.confirming.toString(), contains('confirming'));
      expect(UqpayCancelReason.fromRaw('x').toString(), 'UqpayCancelReason(x)');
      expect((result as UqpayPaymentCompleted).attempt, isNull);
      expect(result.intent.id, 'pi_123');
      const failed = UqpayPaymentFailed(
        intentId: 'pi_1',
        error: UqpayError(
          code: UqpayErrorCode.unknown,
          developerMessage: 'd',
          userMessage: 'u',
          isRetryable: false,
        ),
      );
      expect(failed.toString(), contains('unknown'));
      expect(failed.intent, isNull);
      const canceled = UqpayPaymentCanceled(
        intentId: 'pi_1',
        reason: UqpayCancelReason.userDismissed,
      );
      expect(canceled.toString(), contains('user_dismissed'));
      expect(canceled.intent, isNull);
      expect(
        const UqpayIntentRetrieved(
          UqpayPaymentIntent(id: 'pi_9', status: UqpayIntentStatus.pending),
        ).toString(),
        'UqpayIntentRetrieved(pi_9)',
      );
    });
  });
}
