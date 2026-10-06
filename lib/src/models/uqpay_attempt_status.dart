import 'package:flutter/foundation.dart';

/// The status of a single payment attempt (`attempt_status` on the wire).
///
/// An **open value type**, not a Dart `enum`: unrecognised wire values decode
/// to an instance with [isUnknown] `true` and [raw] preserved. The SDK itself
/// only ever *reads* [failed] (decline detection); the other values are
/// pass-through data for merchants.
@immutable
class UqpayAttemptStatus {
  const UqpayAttemptStatus._(this.raw);

  /// Decodes a wire value. Never throws; unknown values are preserved.
  factory UqpayAttemptStatus.fromRaw(String raw) => UqpayAttemptStatus._(raw);

  /// The attempt was created.
  static const UqpayAttemptStatus initiated = UqpayAttemptStatus._('INITIATED');

  /// The customer was sent to an authentication (3-D Secure) step.
  static const UqpayAttemptStatus authenticationRedirected =
      UqpayAttemptStatus._('AUTHENTICATION_REDIRECTED');

  /// Authorisation is pending.
  static const UqpayAttemptStatus pendingAuthorization = UqpayAttemptStatus._(
    'PENDING_AUTHORIZATION',
  );

  /// Authorised, not yet captured.
  static const UqpayAttemptStatus authorized = UqpayAttemptStatus._(
    'AUTHORIZED',
  );

  /// Capture has been requested.
  static const UqpayAttemptStatus captureRequested = UqpayAttemptStatus._(
    'CAPTURE_REQUESTED',
  );

  /// Funds settled.
  static const UqpayAttemptStatus settled = UqpayAttemptStatus._('SETTLED');

  /// The attempt succeeded.
  static const UqpayAttemptStatus succeeded = UqpayAttemptStatus._('SUCCEEDED');

  /// The attempt was cancelled.
  static const UqpayAttemptStatus cancelled = UqpayAttemptStatus._('CANCELLED');

  /// The attempt expired before completion.
  static const UqpayAttemptStatus expired = UqpayAttemptStatus._('EXPIRED');

  /// The attempt failed — read `failure_code` for the reason.
  static const UqpayAttemptStatus failed = UqpayAttemptStatus._('FAILED');

  /// Every status the SDK recognises.
  static const List<UqpayAttemptStatus> known = <UqpayAttemptStatus>[
    initiated,
    authenticationRedirected,
    pendingAuthorization,
    authorized,
    captureRequested,
    settled,
    succeeded,
    cancelled,
    expired,
    failed,
  ];

  /// The exact wire value, e.g. `"FAILED"`.
  final String raw;

  /// Whether [raw] is a value the SDK does not recognise.
  bool get isUnknown => !known.contains(this);

  /// Whether the attempt can no longer change: `SETTLED`, `SUCCEEDED`,
  /// `CANCELLED`, `EXPIRED` or `FAILED`.
  bool get isTerminal =>
      this == settled ||
      this == succeeded ||
      this == cancelled ||
      this == expired ||
      this == failed;

  /// Whether the attempt represents money successfully taken or authorised:
  /// `AUTHORIZED`, `CAPTURE_REQUESTED`, `SETTLED` or `SUCCEEDED`. Never
  /// `true` for an unknown status.
  bool get isSuccess =>
      this == authorized ||
      this == captureRequested ||
      this == settled ||
      this == succeeded;

  @override
  bool operator ==(Object other) =>
      other is UqpayAttemptStatus && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UqpayAttemptStatus($raw)';
}
