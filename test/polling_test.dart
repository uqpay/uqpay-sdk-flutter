import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

import 'support/fakes.dart';

/// Polling schedule, monotonic / suspension-proof
/// deadlines, pause/resume with one immediate reconcile,
/// and the timer/subscription leak test — all driven by the
/// [ManualClock], whose time moves only when the test says so.
void main() {
  late ManualClock clock;
  late PaymentsHarness h;

  UqpayHttpResponse pending() =>
      jsonResponse(200, intentJson(status: 'PENDING'));
  UqpayHttpResponse succeeded() =>
      jsonResponse(200, intentJson(status: 'SUCCEEDED'));

  /// A harness with an exact (jitter-free) schedule: 2 s × 1.5, capped at
  /// 10 s. The budget comes from `createFlow(outcomeDeadline:)`.
  void harness() {
    clock = ManualClock();
    h = PaymentsHarness(clock: clock, policy: PollingPolicy(jitter: 0));
  }

  /// Lets every microtask and already-completed timer callback run.
  Future<void> pump() => pumpEventQueue(times: 50);

  setUp(harness);

  group('request schedule', () {
    test('back-off is 2 s, 3 s, 4.5 s, 6.75 s, 10 s, 10 s … and stops on '
        'terminal', () async {
      h.http.enqueue(pending()); // guard read
      for (var i = 0; i < 5; i++) {
        h.http.enqueue(pending());
      }
      h.http.enqueue(succeeded());
      final flow = h.payments.createFlow(intentId: 'pi_123');
      unawaited(flow.awaitOutcome());
      await pump();
      expect(h.reads, hasLength(1), reason: 'guard only; first poll waits');

      const expected = <Duration>[
        Duration(seconds: 2),
        Duration(seconds: 3),
        Duration(microseconds: 4500000),
        Duration(microseconds: 6750000),
        Duration(seconds: 10),
        Duration(seconds: 10),
      ];
      for (var i = 0; i < expected.length; i++) {
        expect(clock.pendingTimers, 1);
        expect(clock.requestedDelays.last, expected[i]);
        // Just short of the due time: no request.
        clock.advance(expected[i] - const Duration(milliseconds: 1));
        await pump();
        expect(h.reads, hasLength(1 + i));
        clock.advance(const Duration(milliseconds: 1));
        await pump();
        expect(h.reads, hasLength(2 + i));
      }
      expect(await flow.result, isA<UqpayPaymentCompleted>());
      expect(clock.pendingTimers, 0, reason: 'no timer after terminal');
      // Nothing more is sent even if time keeps passing.
      clock.advance(const Duration(hours: 1));
      await pump();
      expect(h.reads, hasLength(7));
      expect(clock.requestedDelays, expected);
    });

    test('never polls sub-second and jitter stays within ±20 %', () {
      final policy = PollingPolicy(random: Random(7));
      for (var attempt = 0; attempt < 20; attempt++) {
        final wait = policy.waitBefore(attempt);
        expect(wait, greaterThanOrEqualTo(const Duration(seconds: 1)));
        final base = attempt == 0
            ? 2.0
            : min(10, 2 * pow(1.5, attempt).toDouble());
        expect(wait.inMilliseconds, greaterThanOrEqualTo(base * 800 - 1));
        expect(wait.inMilliseconds, lessThanOrEqualTo(base * 1200 + 1));
      }
      expect(() => PollingPolicy(jitter: 1), throwsArgumentError);
      expect(() => PollingPolicy(multiplier: 0.5), throwsArgumentError);
      expect(() => PollingPolicy(initial: Duration.zero), throwsArgumentError);
      expect(() => PollingPolicy(budget: Duration.zero), throwsArgumentError);
    });

    test('a terminal intent is never polled: one read, no timer', () async {
      h.http.enqueue(succeeded());
      final result = await h.payments.awaitOutcome('pi_123');
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.reads, hasLength(1));
      expect(clock.requestedDelays, isEmpty);
      expect(clock.pendingTimers, 0);
    });

    test(
      'the budget is attempt-counted: Pending(timeout) when spent',
      () async {
        h.http.enqueue(pending());
        for (var i = 0; i < 4; i++) {
          h.http.enqueue(pending());
        }
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          outcomeDeadline: const Duration(seconds: 20),
        );
        unawaited(flow.awaitOutcome());
        // 2 + 3 + 4.5 + 6.75 = 16.25 s fits; the next 10 s wait would exceed
        // 20 s.
        for (var i = 0; i < 4; i++) {
          await pump();
          clock.advance(const Duration(seconds: 10));
        }
        await pump();
        final result = await flow.result;
        expect(result, isA<UqpayPaymentPending>());
        final p = result as UqpayPaymentPending;
        expect(p.cause?.code, UqpayErrorCode.timeout);
        expect(p.cause?.isOutcomeUnknown, isTrue);
        expect(p.lastKnownStatus, UqpayIntentStatus.pending);
        expect(h.reads, hasLength(5));
        expect(clock.pendingTimers, 0);
      },
    );
  });

  group('deadlines survive suspension', () {
    test(
      'budget spent while reads keep failing → Pending(last error)',
      () async {
        h.http.enqueue(pending());
        for (var i = 0; i < 6; i++) {
          h.http.enqueue(jsonResponse(502, 'bad gateway'));
        }
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          outcomeDeadline: const Duration(seconds: 12),
        );
        unawaited(flow.awaitOutcome());
        for (var i = 0; i < 4; i++) {
          await pump();
          clock.advance(const Duration(seconds: 10));
        }
        await pump();
        final result = await flow.result as UqpayPaymentPending;
        expect(result.cause?.code, UqpayErrorCode.serverError);
        expect(result.lastKnownStatus, UqpayIntentStatus.pending);
      },
    );

    test(
      'a 10-minute clock jump mid-wait causes no spurious timeout',
      () async {
        h.http
          ..enqueue(pending())
          ..enqueue(pending())
          ..enqueue(succeeded());
        final flow = h.payments.createFlow(intentId: 'pi_123');
        unawaited(flow.awaitOutcome());
        await pump();
        // The app is suspended for ten minutes while a 2 s wait is outstanding
        // (the budget is 5 minutes). Wall and monotonic time both jump.
        clock.advance(const Duration(minutes: 10));
        await pump();
        expect(flow.isDone, isFalse, reason: 'budget counts scheduled waits');
        expect(h.reads, hasLength(2), reason: 'polled once on waking');
        clock.advance(const Duration(seconds: 3));
        await pump();
        expect(await flow.result, isA<UqpayPaymentCompleted>());
      },
    );

    test('a wall-clock change alone changes nothing', () async {
      h.http
        ..enqueue(pending())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(intentId: 'pi_123');
      unawaited(flow.awaitOutcome());
      await pump();
      clock.advanceWallClockOnly(const Duration(days: 2));
      await pump();
      expect(h.reads, hasLength(1));
      clock.advance(const Duration(seconds: 2));
      await pump();
      expect(await flow.result, isA<UqpayPaymentCompleted>());
    });
  });

  group('pause / resume', () {
    test('paused: no request even when the wait elapses; resume polls at '
        'once, then continues the schedule', () async {
      h.http
        ..enqueue(pending())
        ..enqueue(pending())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(intentId: 'pi_123');
      final phases = <UqpayPaymentPhase>[];
      flow.status.listen((s) => phases.add(s.phase));
      unawaited(flow.awaitOutcome());
      await pump();

      flow.pause();
      expect(flow.isPaused, isTrue);
      clock.advance(const Duration(minutes: 1));
      await pump();
      expect(h.reads, hasLength(1), reason: 'nothing sent while paused');
      expect(phases, contains(UqpayPaymentPhase.paused));

      flow.resume();
      await pump();
      expect(h.reads, hasLength(2), reason: 'one immediate reconcile');
      expect(clock.pendingTimers, 1, reason: 'back on the schedule');
      expect(clock.requestedDelays.last, const Duration(seconds: 3));

      clock.advance(const Duration(seconds: 3));
      await pump();
      expect(await flow.result, isA<UqpayPaymentCompleted>());
      expect(clock.pendingTimers, 0);
    });

    test('resume during an outstanding wait cuts it short', () async {
      h.http
        ..enqueue(pending())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(intentId: 'pi_123');
      unawaited(flow.awaitOutcome());
      await pump();
      flow
        ..pause()
        ..resume();
      await pump();
      expect(h.reads, hasLength(2), reason: 'polled without waiting 2 s');
      expect(clock.cancelledDelays, 1);
      expect(await flow.result, isA<UqpayPaymentCompleted>());
    });

    test('cancel while paused → Pending, gate released, no timers', () async {
      h.http.enqueue(pending());
      final flow = h.payments.createFlow(intentId: 'pi_123');
      unawaited(flow.awaitOutcome());
      await pump();
      flow.pause();
      clock.advance(const Duration(seconds: 2));
      await pump();
      flow.cancel(UqpayCancelReason.userDismissed);
      final result = await flow.result;
      expect(result, isA<UqpayPaymentPending>());
      expect(flow.isPaused, isFalse);
      expect(clock.pendingTimers, 0);
      expect(h.reads, hasLength(1));
    });

    test('pause/resume on an idle or finished flow are no-ops', () async {
      h.http.enqueue(succeeded());
      final flow = h.payments.createFlow(intentId: 'pi_123')
        ..pause()
        ..resume()
        ..resume();
      expect(flow.isPaused, isFalse);
      await flow.awaitOutcome();
      flow
        ..pause()
        ..resume();
      expect(flow.isPaused, isFalse);
    });
  });

  group('no leaks after terminal', () {
    test(
      'stream closed, no live timer, no further events — success path',
      () async {
        h.http
          ..enqueue(pending())
          ..enqueue(succeeded());
        final flow = h.payments.createFlow(intentId: 'pi_123');
        var done = false;
        var events = 0;
        final sub = flow.status.listen(
          (_) => events++,
          onDone: () => done = true,
        );
        unawaited(flow.awaitOutcome());
        await pump();
        clock.advance(const Duration(seconds: 2));
        await pump();
        await flow.result;
        await pump();
        expect(done, isTrue, reason: 'stream closed on terminal');
        expect(clock.pendingTimers, 0);
        final seen = events;
        clock.advance(const Duration(hours: 1));
        await pump();
        expect(events, seen);
        await sub.cancel();
      },
    );

    test('cancel mid-poll cancels the outstanding timer', () async {
      h.http.enqueue(pending());
      final flow = h.payments.createFlow(intentId: 'pi_123');
      var done = false;
      flow.status.listen((_) {}, onDone: () => done = true);
      unawaited(flow.awaitOutcome());
      await pump();
      expect(clock.pendingTimers, 1);
      flow.cancel(UqpayCancelReason.merchantCancelled);
      await flow.result;
      await pump();
      expect(clock.pendingTimers, 0);
      expect(clock.cancelledDelays, 1);
      expect(done, isTrue);
    });

    test(
      'a late listener on a finished flow gets onDone immediately',
      () async {
        h.http.enqueue(succeeded());
        final flow = h.payments.createFlow(intentId: 'pi_123');
        await flow.awaitOutcome();
        final events = await flow.status.toList();
        expect(events, isEmpty);
      },
    );
  });

  group('clock seam', () {
    test('SystemUqpayClock.startDelay is cancellable and completes', () async {
      final clock = SystemUqpayClock();
      final delay = clock.startDelay(const Duration(hours: 1));
      var completed = false;
      unawaited(delay.future.then((_) => completed = true));
      delay.cancel();
      await pumpEventQueue();
      expect(completed, isTrue);
      delay.cancel(); // idempotent
      final short = clock.startDelay(const Duration(milliseconds: 5));
      await short.future;
      expect(clock.elapsed, greaterThan(Duration.zero));
    });

    test(
      'the default startDelay wraps delay and cancel completes early',
      () async {
        final fake = FakeClock();
        final delay = fake.startDelay(const Duration(seconds: 1))..cancel();
        await delay.future;
        expect(fake.delays, [const Duration(seconds: 1)]);
      },
    );
  });
}
