import 'package:flutter/foundation.dart';

/// The lifecycle status of a payment intent (`intent_status` on the wire).
///
/// This is an **open value type**, not a Dart `enum`: the server can add a
/// status at any time and an already-shipped app must keep working.
/// Compare against the static constants
/// (`status == UqpayIntentStatus.succeeded`) or use the semantic getters
/// ([isTerminal], [isSuccess], [shouldPoll]); an unrecognised wire value
/// decodes to an instance with [isUnknown] `true` and [raw] preserved — it
/// never throws.
///
/// Semantics the SDK relies on, per the gateway's documented status rules:
///
/// | Wire value | terminal | success | poll |
/// |---|---|---|---|
/// | `REQUIRES_PAYMENT_METHOD` | no | no | no — attempt failed / nothing attached |
/// | `REQUIRES_CUSTOMER_ACTION` | no | no | yes |
/// | `REQUIRES_CAPTURE` | no | **yes** — authorised, settlement pending | no |
/// | `PENDING` | **no** | no | yes |
/// | `PROCESSING` (legacy) | no | no | yes |
/// | `SUCCEEDED` | yes | yes | no |
/// | `CANCELLED` / `CANCELED` | yes | no | no |
/// | `FAILED` | yes | no | no |
/// | anything else | no | no | yes |
@immutable
class UqpayIntentStatus {
  /// Wraps a wire value verbatim. Prefer [UqpayIntentStatus.fromRaw].
  const UqpayIntentStatus._(this.raw);

  /// Decodes a wire value. Never throws; unknown values are preserved.
  factory UqpayIntentStatus.fromRaw(String raw) => UqpayIntentStatus._(raw);

  /// No payment method is attached, or the last attempt failed and the
  /// customer must try again.
  static const UqpayIntentStatus requiresPaymentMethod = UqpayIntentStatus._(
    'REQUIRES_PAYMENT_METHOD',
  );

  /// The customer must complete an action described by `next_action`
  /// (3-D Secure challenge, QR scan, redirect).
  static const UqpayIntentStatus requiresCustomerAction = UqpayIntentStatus._(
    'REQUIRES_CUSTOMER_ACTION',
  );

  /// Authorisation is complete; capture/settlement remains. **Reported as a
  /// success** — the customer has paid from their point of view.
  static const UqpayIntentStatus requiresCapture = UqpayIntentStatus._(
    'REQUIRES_CAPTURE',
  );

  /// Settlement is in flight (bank transfer, wallet scan registered). Not
  /// terminal — keep polling.
  static const UqpayIntentStatus pending = UqpayIntentStatus._('PENDING');

  /// Legacy non-terminal status still emitted by some backends.
  static const UqpayIntentStatus processing = UqpayIntentStatus._('PROCESSING');

  /// Paid. Terminal.
  static const UqpayIntentStatus succeeded = UqpayIntentStatus._('SUCCEEDED');

  /// The intent was cancelled. Terminal.
  static const UqpayIntentStatus cancelled = UqpayIntentStatus._('CANCELLED');

  /// The intent failed. Terminal.
  static const UqpayIntentStatus failed = UqpayIntentStatus._('FAILED');

  /// Every status the SDK recognises.
  static const List<UqpayIntentStatus> known = <UqpayIntentStatus>[
    requiresPaymentMethod,
    requiresCustomerAction,
    requiresCapture,
    pending,
    processing,
    succeeded,
    cancelled,
    failed,
  ];

  /// The exact wire value, e.g. `"SUCCEEDED"`.
  final String raw;

  /// Whether [raw] is a status the SDK recognises. `CANCELED` (one L, seen
  /// from older backends) counts as known.
  bool get isUnknown => !isCancelled && !known.contains(this);

  /// `CANCELLED` or its legacy one-L spelling `CANCELED`.
  bool get isCancelled => raw == 'CANCELLED' || raw == 'CANCELED';

  /// Whether the intent can no longer change: `SUCCEEDED`, `CANCELLED`,
  /// `FAILED`. `PENDING` is **not** terminal.
  bool get isTerminal => this == succeeded || isCancelled || this == failed;

  /// Whether the status means the customer has paid: `SUCCEEDED` or
  /// `REQUIRES_CAPTURE` (an earlier native SDK wrongly reported
  /// the latter as failed). Never `true` for an unknown status.
  bool get isSuccess => this == succeeded || this == requiresCapture;

  /// Whether a poller should keep re-reading the intent: neither terminal
  /// nor success nor `REQUIRES_PAYMENT_METHOD`. Unknown statuses poll (fail
  /// open — they resolve to a known status or the poll budget expires).
  bool get shouldPoll =>
      !isTerminal && !isSuccess && this != requiresPaymentMethod;

  @override
  bool operator ==(Object other) =>
      other is UqpayIntentStatus && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UqpayIntentStatus($raw)';
}
