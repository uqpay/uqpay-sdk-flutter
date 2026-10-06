import 'package:flutter/foundation.dart';

/// Why a payment ended in `UqpayPaymentCanceled`.
///
/// An **open value type** wrapping a `String` — not an enum — so the SDK (or
/// a future payment method) can introduce a new reason in a minor release
/// without breaking a merchant's `switch`. Compare against the constants;
/// unrecognised values report [isUnknown] `true` with [raw] preserved.
///
/// The three local reasons the SDK keeps
/// distinguishable are [userDismissed], [userTappedCancel] and
/// [merchantCancelled]. [intentCancelled] is the server-side case: the intent
/// was already `CANCELLED` when the SDK read it.
@immutable
class UqpayCancelReason {
  const UqpayCancelReason._(this.raw);

  /// Wraps a raw reason. Never throws.
  factory UqpayCancelReason.fromRaw(String raw) => UqpayCancelReason._(raw);

  /// The customer dismissed the payment UI (drag-down, tap-outside, system
  /// back) before any confirm was sent.
  static const UqpayCancelReason userDismissed = UqpayCancelReason._(
    'user_dismissed',
  );

  /// The customer tapped an explicit Cancel control before any confirm was
  /// sent.
  static const UqpayCancelReason userTappedCancel = UqpayCancelReason._(
    'user_tapped_cancel',
  );

  /// The merchant's code cancelled the flow (`UqpayPaymentFlow.cancel`) or
  /// cancelled the intent on the server (`UqpayPayments.cancelIntent`).
  static const UqpayCancelReason merchantCancelled = UqpayCancelReason._(
    'merchant_cancelled',
  );

  /// The intent was already `CANCELLED` on the server when the SDK read it —
  /// nothing was attempted. `UqpayPaymentIntent.cancellationReason` carries
  /// the server's reason string.
  static const UqpayCancelReason intentCancelled = UqpayCancelReason._(
    'intent_cancelled',
  );

  /// Every reason the SDK defines.
  static const List<UqpayCancelReason> known = <UqpayCancelReason>[
    userDismissed,
    userTappedCancel,
    merchantCancelled,
    intentCancelled,
  ];

  /// The reason string, e.g. `user_dismissed`.
  final String raw;

  /// Whether [raw] is a reason this version of the SDK does not define.
  bool get isUnknown => !known.contains(this);

  @override
  bool operator ==(Object other) =>
      other is UqpayCancelReason && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UqpayCancelReason($raw)';
}
