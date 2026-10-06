import 'dart:async';

/// The SDK's single source of time.
///
/// Every timeout, poll deadline, expiry and delay in the SDK goes through an
/// instance of this class, so tests can drive time deterministically and so a
/// user who backgrounds the app for ten minutes never sees a spurious timeout
/// computed from wall-clock arithmetic.
///
/// Two notions of time are deliberately kept apart:
///
/// * [elapsed] is **monotonic**, backed by a [Stopwatch]. Use it for every
///   deadline and budget. It never jumps when the device clock is adjusted.
/// * [now] is the **wall clock**. It exists only for values that must survive
///   a process restart — the 24 h idempotency-pin expiry — where a monotonic
///   reading is meaningless across processes.
///
/// This file is the only place in `lib/src/` permitted to call
/// `DateTime.now()`, `Future.delayed` or construct a `Timer`; a test greps
/// for all three.
abstract class UqpayClock {
  /// Creates a clock. Subclasses call this.
  const UqpayClock();

  /// Monotonic time elapsed since this clock was created.
  ///
  /// Backed by a [Stopwatch]; unaffected by wall-clock changes.
  Duration get elapsed;

  /// The current wall-clock time in UTC.
  ///
  /// Only for persisted expiries. Never use it to compute a deadline that
  /// lives inside one process — use [elapsed].
  DateTime now();

  /// Completes after [duration] has passed.
  ///
  /// The SDK never calls `Future.delayed` directly; it always waits through
  /// this method so tests can fast-forward.
  Future<void> delay(Duration duration);

  /// Starts a **cancellable** wait of [duration].
  ///
  /// The payment flow uses this for poll back-off so a cancel, pause or
  /// resume can wake the loop early and so no timer outlives a finished flow.
  /// The default implementation wraps [delay] — the underlying
  /// wait cannot be cut short, but [UqpayDelay.cancel] still completes the
  /// returned future immediately. [SystemUqpayClock] overrides it with a real
  /// cancellable timer.
  UqpayDelay startDelay(Duration duration) {
    final completer = Completer<void>();
    unawaited(
      delay(duration).then((_) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }),
    );
    return UqpayDelay(completer.future, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
  }
}

/// A wait started by [UqpayClock.startDelay].
///
/// [future] completes when the duration has passed **or** when [cancel] is
/// called, whichever comes first. Callers that need to know which one it was
/// keep their own flag; the flow does.
class UqpayDelay {
  /// Creates a delay handle. [cancel] must be idempotent and must complete
  /// [future] if it has not completed yet.
  UqpayDelay(this.future, void Function() cancel) : _cancel = cancel;

  /// Completes when the delay elapses or is cancelled.
  final Future<void> future;

  final void Function() _cancel;

  /// Stops the underlying timer (if any) and completes [future] now.
  /// Idempotent.
  void cancel() => _cancel();
}

/// The production [UqpayClock]: a real [Stopwatch], the real wall clock and
/// real timers.
class SystemUqpayClock extends UqpayClock {
  /// Creates a clock whose [elapsed] starts counting immediately.
  SystemUqpayClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration get elapsed => _stopwatch.elapsed;

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  Future<void> delay(Duration duration) => Future<void>.delayed(duration);

  @override
  UqpayDelay startDelay(Duration duration) {
    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return UqpayDelay(completer.future, () {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
  }
}
