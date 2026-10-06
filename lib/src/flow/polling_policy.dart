import 'dart:math';

import 'package:flutter/foundation.dart';

/// How the payment flow spaces its status polls.
///
/// Bounded exponential back-off with jitter: the *n*-th wait is
/// `min(initial × multiplier^n, maximum)` scaled by a random factor in
/// `[1 − jitter, 1 + jitter]`, and never below [floor] (no sub-second
/// polling). The budget is **attempt-counted**: [budget] is compared with the
/// sum of the waits the flow actually scheduled, not with wall-clock time,
/// so a suspended app does not burn it.
///
/// Internal. The defaults follow the iOS cadences: 2 s between polls with a
/// 300 s budget for a card / 3-D Secure outcome; QR flows pass a 600 s
/// budget.
@immutable
class PollingPolicy {
  /// Creates a policy. [random] is injectable so tests can pin the jitter;
  /// pass `jitter: 0` for an exact schedule.
  PollingPolicy({
    this.initial = const Duration(seconds: 2),
    this.multiplier = 1.5,
    this.maximum = const Duration(seconds: 10),
    this.jitter = 0.2,
    this.floor = const Duration(seconds: 1),
    this.budget = const Duration(minutes: 5),
    Random? random,
  }) : _random = random ?? Random() {
    if (initial <= Duration.zero) {
      throw ArgumentError.value(initial, 'initial', 'must be positive');
    }
    if (multiplier < 1) {
      throw ArgumentError.value(multiplier, 'multiplier', 'must be ≥ 1');
    }
    if (jitter < 0 || jitter >= 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be in [0, 1)');
    }
    if (budget <= Duration.zero) {
      throw ArgumentError.value(budget, 'budget', 'must be positive');
    }
  }

  /// First wait.
  final Duration initial;

  /// Growth factor per wait.
  final double multiplier;

  /// Longest wait before jitter.
  final Duration maximum;

  /// Jitter fraction, `0` for none.
  final double jitter;

  /// Shortest wait after jitter (no sub-second polling).
  final Duration floor;

  /// Total scheduled waiting allowed before the flow gives up with
  /// `UqpayPaymentPending`.
  final Duration budget;

  final Random _random;

  /// Returns a copy with a different [budget].
  PollingPolicy withBudget(Duration budget) => PollingPolicy(
    initial: initial,
    multiplier: multiplier,
    maximum: maximum,
    jitter: jitter,
    floor: floor,
    budget: budget,
    random: _random,
  );

  /// The wait before poll number [attempt] (0-based), with jitter applied.
  Duration waitBefore(int attempt) {
    var micros = initial.inMicroseconds;
    for (var i = 0; i < attempt; i++) {
      micros = (micros * multiplier).round();
      if (micros >= maximum.inMicroseconds) {
        micros = maximum.inMicroseconds;
        break;
      }
    }
    if (jitter > 0) {
      final factor = 1 - jitter + _random.nextDouble() * 2 * jitter;
      micros = (micros * factor).round();
    }
    final wait = Duration(microseconds: micros);
    return wait < floor ? floor : wait;
  }
}
