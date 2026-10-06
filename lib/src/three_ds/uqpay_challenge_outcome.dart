import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';

/// How presenting a 3-D Secure / redirect challenge ended, as seen by the
/// presenter.
///
/// **This is a signal, never a payment result.** The outcome of the payment
/// arrives at UQPAY by webhook; after any of these the
/// SDK re-queries the intent and maps the *server's* status. In particular
/// [UqpayChallengeReturned.returnUri] is attacker-writable and its query
/// string is never read for a status.
///
/// **These four variants are frozen for the whole 1.x line**:
/// adding a case would break every exhaustive `switch` over this sealed
/// type. New failure modes are expressed as new [UqpayError.code] values
/// inside [UqpayChallengeOutcome.failed] — an open set — never as a fifth
/// subclass. (The same rule `UqpayPaymentResult` follows.)
@immutable
sealed class UqpayChallengeOutcome {
  const UqpayChallengeOutcome();

  /// The customer navigated back to the return URL (or an app scheme).
  const factory UqpayChallengeOutcome.returned(Uri returnUri) =
      UqpayChallengeReturned;

  /// The customer closed the challenge UI. They may have authenticated first
  /// and then closed — never assume cancellation; reconcile.
  const factory UqpayChallengeOutcome.dismissedByUser() =
      UqpayChallengeDismissed;

  /// The challenge could not be presented or broke while presenting.
  const factory UqpayChallengeOutcome.failed(UqpayError error) =
      UqpayChallengeFailed;

  /// The challenge deadline passed without a return. The payment may still
  /// be live — reconcile, never report a decline from this alone.
  const factory UqpayChallengeOutcome.timedOut() = UqpayChallengeTimedOut;
}

/// See [UqpayChallengeOutcome.returned].
final class UqpayChallengeReturned extends UqpayChallengeOutcome {
  /// Creates a returned outcome.
  const UqpayChallengeReturned(this.returnUri);

  /// The URL the customer came back on. A navigation sentinel only: never
  /// trusted for the payment's status.
  final Uri returnUri;

  @override
  String toString() => 'UqpayChallengeOutcome.returned';
}

/// See [UqpayChallengeOutcome.dismissedByUser].
final class UqpayChallengeDismissed extends UqpayChallengeOutcome {
  /// Creates a dismissed outcome.
  const UqpayChallengeDismissed();

  @override
  String toString() => 'UqpayChallengeOutcome.dismissedByUser';
}

/// See [UqpayChallengeOutcome.failed].
final class UqpayChallengeFailed extends UqpayChallengeOutcome {
  /// Creates a failed outcome.
  const UqpayChallengeFailed(this.error);

  /// What went wrong while presenting.
  final UqpayError error;

  @override
  String toString() => 'UqpayChallengeOutcome.failed(${error.code.raw})';
}

/// See [UqpayChallengeOutcome.timedOut].
final class UqpayChallengeTimedOut extends UqpayChallengeOutcome {
  /// Creates a timed-out outcome.
  const UqpayChallengeTimedOut();

  @override
  String toString() => 'UqpayChallengeOutcome.timedOut';
}
