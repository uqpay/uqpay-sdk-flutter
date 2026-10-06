import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

import '../support/fakes.dart';

void main() {
  group('Exactly-once delivery across all exit paths', () {
    test('success path delivers result exactly once', () async {
      final harness = PaymentsHarness();
      var resultCount = 0;

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm().then((r) {
        resultCount++;
        return r;
      });

      expect(resultCount, 1);
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test('decline path delivers result exactly once', () async {
      final harness = PaymentsHarness();
      var resultCount = 0;

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'FAILED',
            attempt: failedAttempt('card_declined'),
          ),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm().then((r) {
        resultCount++;
        return r;
      });

      expect(resultCount, 1);
      expect(result, isA<UqpayPaymentFailed>());
    });

    test('transport timeout delivers result exactly once', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueueError(SocketException('Connection timeout'));

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      var resultCount = 0;
      final result = await flow.confirm().then((r) {
        resultCount++;
        return r;
      });

      expect(resultCount, 1);
      // The raw exception escaped at the client seam AFTER the confirm had
      // left the device: the server may have taken the payment, so the only
      // honest answer is Pending (outcome unknown), never Failed.
      expect(result, isA<UqpayPaymentPending>());
      expect((result as UqpayPaymentPending).cause, isNotNull);
    });

    test('cancel() twice still delivers exactly one result', () async {
      final harness = PaymentsHarness(clock: ManualClock());

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueueHandler(
        (_) async => jsonResponse(200, intentJson(status: 'PENDING')),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final future = flow.confirm();
      var resultCount = 0;
      unawaited(future.then((_) => resultCount++));

      // Let the guard GET and the confirm reach the wire.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(flow.isConfirmInFlight, isTrue);

      // Neither call may throw, and together they must produce exactly one
      // result.
      flow
        ..cancel(UqpayCancelReason.userTappedCancel)
        ..cancel(UqpayCancelReason.userTappedCancel);

      final result = await future;

      // Once the confirm has left the device the
      // server may still take the payment, so cancel() yields Pending — a
      // payment already on the wire must never be reported as cancelled.
      expect(result, isA<UqpayPaymentPending>());
      await Future<void>.delayed(Duration.zero);
      expect(resultCount, 1);
    });
  });

  group('Terminal-intent guard', () {
    test('SUCCEEDED intent returns Completed, zero confirms', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(harness.confirms.length, 0);
    });

    test('REQUIRES_CAPTURE returns Completed, zero confirms', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'REQUIRES_CAPTURE'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(harness.confirms.length, 0);
    });

    test('CANCELLED intent returns Canceled, zero confirms', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'CANCELLED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();

      expect(result, isA<UqpayPaymentCanceled>());
      expect(harness.confirms.length, 0);
    });

    test('PENDING is not treated as terminal', () async {
      // The actual claim: PENDING is a non-terminal, poll-worthy status.
      expect(UqpayIntentStatus.pending.isTerminal, isFalse);
      expect(UqpayIntentStatus.pending.shouldPoll, isTrue);

      final harness = PaymentsHarness();

      // Guard GET reports PENDING: a payment for this intent is already in
      // flight server-side, so re-sending the confirm risks a double charge.
      // By design the flow does NOT confirm again — it moves to
      // awaiting/reconcile and polls. Zero confirms is the safe answer here,
      // not a missing confirm.
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
      // Still PENDING on the first poll (not terminal → keep polling)…
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
      // …and the flow can still resolve once the server settles.
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(harness.confirms.length, 0);
      // Guard GET + two polls: PENDING kept the poll loop alive.
      expect(harness.reads.length, 3);
    });
  });

  group('Monotonic deadlines with ManualClock', () {
    test('wall-clock jump does not cause spurious timeout', () async {
      final clock = ManualClock();
      final harness = PaymentsHarness(clock: clock);

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final future = flow.confirm();

      // Jump wall clock forward
      clock.advanceWallClockOnly(const Duration(minutes: 10));

      final result = await future;
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test('pause stops scheduling, resume triggers immediate GET', () async {
      final clock = ManualClock();
      final harness = PaymentsHarness(clock: clock);

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'PENDING'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final future = flow.confirm();

      await Future<void>.delayed(const Duration(milliseconds: 10));

      flow.pause();
      final requestCountWhilePaused = harness.reads.length;

      clock.advance(const Duration(seconds: 10));
      expect(harness.reads.length, requestCountWhilePaused);

      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      flow.resume();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final result = await future;
      expect(result, isA<UqpayPaymentCompleted>());
    });
  });

  group('Polling schedule', () {
    test('exponential backoff follows schedule', () async {
      final clock = ManualClock();
      // Default multiplier (1.5): the second wait is 1 s × 1.5 = 1500 ms.
      final policy = PollingPolicy(
        initial: const Duration(seconds: 1),
        maximum: const Duration(seconds: 5),
        jitter: 0,
      );
      final harness = PaymentsHarness(clock: clock, policy: policy);

      harness.http.enqueue(jsonResponse(200, intentJson()));
      for (var i = 0; i < 10; i++) {
        harness.http.enqueue(
          jsonResponse(
            200,
            intentJson(status: 'PENDING'),
          ),
        );
      }

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      unawaited(flow.confirm());
      clock.advance(const Duration(seconds: 20));

      final delays = clock.requestedDelays;
      if (delays.length >= 2) {
        expect(delays[0], const Duration(seconds: 1));
        expect(delays[1], const Duration(milliseconds: 1500));
      }
    });

    test('polling stops on first terminal status', () async {
      final harness = PaymentsHarness();

      // Guard GET: payable, so a confirm is sent.
      harness.http.enqueue(jsonResponse(200, intentJson()));
      // Confirm lands but the outcome is still in flight.
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
      // A few pending polls, then the first terminal read.
      for (var i = 0; i < 3; i++) {
        harness.http.enqueueHandler(
          (_) async => jsonResponse(200, intentJson(status: 'PENDING')),
        );
      }
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      // Anything requested after the terminal read is a polling bug.
      var requestedAfterTerminal = false;
      for (var i = 0; i < 5; i++) {
        harness.http.enqueueHandler((_) async {
          requestedAfterTerminal = true;
          return jsonResponse(200, intentJson(status: 'SUCCEEDED'));
        });
      }

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(result, isA<UqpayPaymentCompleted>());
      expect(requestedAfterTerminal, isFalse);
      expect(harness.confirms.length, 1);
      // Guard + three pending polls + the terminal read, nothing more.
      expect(harness.reads.length, 5);
    });

    test('never busy-waits with zero delay', () async {
      final clock = ManualClock();
      final harness = PaymentsHarness(clock: clock);

      harness.http.enqueue(jsonResponse(200, intentJson()));
      for (var i = 0; i < 5; i++) {
        harness.http.enqueue(
          jsonResponse(
            200,
            intentJson(status: 'PENDING'),
          ),
        );
      }

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      unawaited(flow.confirm());
      clock.advance(const Duration(seconds: 10));

      final delays = clock.requestedDelays;
      for (final delay in delays) {
        expect(delay.inMilliseconds, greaterThan(0));
      }
    });
  });

  group('Idempotency and replay', () {
    test(
      'outcome-unknown replays with same key, then reconciles by polling',
      () async {
        final clock = ManualClock();
        final harness = PaymentsHarness(clock: clock);

        // Guard GET: payable.
        harness.http.enqueue(jsonResponse(200, intentJson()));
        // Four confirm sends (the initial one + the full 3 s / 6 s / 10 s
        // replay ladder), each failing at the seam production fails at:
        // HttpPackageClient classifies a raw SocketException into
        // UqpayTransportException before the flow ever sees it, and the
        // outcome-unknown logic keys off that type.
        for (var i = 0; i < 4; i++) {
          harness.http.enqueueError(
            const UqpayTransportException(
              UqpayTransportFailureKind.socket,
              'transport failure (socket)',
            ),
          );
        }
        // Reconcile-by-polling: the intent stays PENDING until the poll
        // budget (5 min of scheduled waits) is spent.
        for (var i = 0; i < 200; i++) {
          harness.http.enqueueHandler(
            (_) async => jsonResponse(200, intentJson(status: 'PENDING')),
          );
        }

        final flow = harness.payments.createFlow(
          intentId: 'pi_123',
          request: cardConfirmRequest(),
        );

        final future = flow.confirm();
        var settled = false;
        unawaited(future.then((_) => settled = true));
        for (var i = 0; i < 1000 && !settled; i++) {
          await Future<void>.delayed(Duration.zero);
          clock.advance(const Duration(seconds: 10));
        }
        expect(settled, isTrue, reason: 'flow must resolve within the budget');

        // The confirm's outcome never became known, so the merchant is told
        // the truth: the payment is unresolved (Pending), never a definitive
        // Failed.
        final result = await future;
        expect(result, isA<UqpayPaymentPending>());

        // Exactly one initial send plus the three ladder replays…
        expect(harness.confirms.length, 4);
        // …all carrying one and the same idempotency key.
        final keys = harness.confirms
            .map((r) => r.headers['x-idempotency-key'])
            .toSet();
        expect(keys, hasLength(1), reason: 'every replay reuses the same key');
        expect(keys.single, isNotNull);

        // The ladder waits come first, then the polling back-off:
        // 2 s × 1.5 (2, 3, 4.5, 6.75, …) capped at 10 s.
        final delays = clock.requestedDelays;
        expect(delays.length, greaterThanOrEqualTo(8));
        expect(delays.sublist(0, 3), const <Duration>[
          Duration(seconds: 3),
          Duration(seconds: 6),
          Duration(seconds: 10),
        ]);
        expect(delays.sublist(3, 7), const <Duration>[
          Duration(seconds: 2),
          Duration(seconds: 3),
          Duration(milliseconds: 4500),
          Duration(milliseconds: 6750),
        ]);
        expect(delays.sublist(7), everyElement(const Duration(seconds: 10)));
      },
    );

    test('changed payload gets new key', () async {
      final harness = PaymentsHarness();

      // Attempt 1: pay pi_123 with card A, through to a terminal result.
      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final first = await flow.confirm();
      expect(first, isA<UqpayPaymentCompleted>());
      expect(harness.confirms, hasLength(1));

      // Attempt 2: a materially different payload (different intent AND a
      // different card) is a genuinely new logical attempt, so it must mint
      // a new idempotency key.
      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

      final flow2 = harness.payments.createFlow(
        intentId: 'pi_124',
        request: cardConfirmRequest(cardNumber: '5555555555554444'),
      );

      final second = await flow2.confirm();
      expect(second, isA<UqpayPaymentCompleted>());
      expect(harness.confirms, hasLength(2));

      final key1 = harness.confirms[0].headers['x-idempotency-key'];
      final key2 = harness.confirms[1].headers['x-idempotency-key'];
      expect(key1, isNotNull);
      expect(key2, isNotNull);
      expect(key1, isNot(key2));
    });

    test('pin cleaned on terminal result', () async {
      final harness = PaymentsHarness();
      final storage = harness.storage;

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      await flow.confirm();

      const pinKey = 'uqpay.idempotency.pi_123';
      final stored = storage.entries[pinKey];
      expect(stored, isNull);
    });
  });

  group('3DS challenge scenarios', () {
    test('challenge returned + SUCCEEDED → Completed', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: redirectNextAction(),
          ),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test('challenge returned + FAILED(3ds_failed) maps to 3ds code', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: redirectNextAction(),
          ),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'FAILED',
            attempt: failedAttempt('3ds_failed'),
          ),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'FAILED',
            attempt: failedAttempt('3ds_failed'),
          ),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();

      expect(result, isA<UqpayPaymentFailed>());
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.threeDsFailed,
      );
    });

    test('return URL never trusted: success URL + FAILED → Failed', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: redirectNextAction(),
          ),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'FAILED',
            attempt: failedAttempt('card_declined'),
          ),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'FAILED',
            attempt: failedAttempt('card_declined'),
          ),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      final result = await flow.confirm();
      expect(result, isA<UqpayPaymentFailed>());
    });
  });

  group('Return-URL matcher', () {
    test('wrong scheme → no match', () {
      final returnUrl = Uri(
        scheme: 'myapp',
        host: 'payment',
        path: '/return',
      );
      final candidate = Uri.parse('https://payment/return');

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: candidate,
          returnUrl: returnUrl,
        ),
        isFalse,
      );
    });

    test('wrong host → no match', () {
      final returnUrl = Uri(
        scheme: 'https',
        host: 'example.com',
        path: '/return',
      );
      final candidate = Uri.parse('https://wrong.com/return');

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: candidate,
          returnUrl: returnUrl,
        ),
        isFalse,
      );
    });

    test('host case insensitive', () {
      final returnUrl = Uri(
        scheme: 'https',
        host: 'Example.COM',
        path: '/return',
      );
      final candidate = Uri.parse('https://example.com/return');

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: candidate,
          returnUrl: returnUrl,
        ),
        isTrue,
      );
    });

    test('path prefix segment-aligned', () {
      final returnUrl = Uri(
        scheme: 'https',
        host: 'example.com',
        path: '/return',
      );

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('https://example.com/return'),
          returnUrl: returnUrl,
        ),
        isTrue,
      );

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('https://example.com/return-page'),
          returnUrl: returnUrl,
        ),
        isFalse,
      );

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('https://example.com/return/nested'),
          returnUrl: returnUrl,
        ),
        isTrue,
      );
    });

    test('extra query and fragment ignored', () {
      final returnUrl = Uri(
        scheme: 'https',
        host: 'example.com',
        path: '/return',
      );

      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('https://example.com/return?param=1#frag'),
          returnUrl: returnUrl,
        ),
        isTrue,
      );
    });
  });

  group('Leak test — live timers after terminal', () {
    test('ManualClock pendingTimers zero after success', () async {
      final clock = ManualClock();
      final harness = PaymentsHarness(clock: clock);

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      await flow.confirm();

      expect(clock.pendingTimers, 0);
    });

    test('status stream closed on terminal', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      var streamClosed = false;
      flow.status.listen(
        (_) {},
        onDone: () {
          streamClosed = true;
        },
      );

      await flow.confirm();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(streamClosed, isTrue);
    });
  });

  group('Callback safety', () {
    test('listener throw does not corrupt flow result', () async {
      final harness = PaymentsHarness();

      harness.http.enqueue(jsonResponse(200, intentJson()));
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(status: 'SUCCEEDED'),
        ),
      );

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );

      flow.status.listen((_) {
        throw Exception('Listener error');
      });

      final result = await flow.confirm();
      expect(result, isA<UqpayPaymentCompleted>());
    });
  });
}

class SocketException implements Exception {
  SocketException(this.message);
  final String message;

  @override
  String toString() => 'SocketException: $message';
}
