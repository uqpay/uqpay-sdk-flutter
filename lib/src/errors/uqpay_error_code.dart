import 'package:flutter/foundation.dart';

/// A stable, typed error code.
///
/// This is an **open value type** wrapping a `String` — deliberately not a
/// Dart `enum` and not a sealed class — so the server can introduce a new
/// failure code without breaking a merchant's `switch` or crashing their
/// parse. Compare against the static constants; an unrecognised server code
/// arrives as an instance with [isUnknown] `true` and [raw] preserved.
///
/// ```dart
/// if (error.code == UqpayErrorCode.insufficientFunds) {
///   // offer another card
/// } else if (error.code.isUnknown) {
///   // show error.userMessage; log error.code.raw for support
/// }
/// ```
///
/// The constants cover the merchant-facing taxonomy the gateway documents
/// plus the distinct transport failures the SDK keeps apart. Codes are
/// lowercase snake_case strings; the wire's `3ds_failed` is kept verbatim.
@immutable
class UqpayErrorCode {
  const UqpayErrorCode._(this.raw);

  /// Wraps a raw code. Known codes compare equal to their constants;
  /// anything else is [isUnknown]. Never throws.
  factory UqpayErrorCode.fromRaw(String raw) => UqpayErrorCode._(raw);

  // ---- Payment outcome ----------------------------------------------------

  /// The issuer declined the card. Ask the customer for another card.
  static const UqpayErrorCode cardDeclined = UqpayErrorCode._('card_declined');

  /// The account has insufficient funds.
  static const UqpayErrorCode insufficientFunds = UqpayErrorCode._(
    'insufficient_funds',
  );

  /// The payment method or request was rejected as invalid.
  static const UqpayErrorCode invalidPaymentMethod = UqpayErrorCode._(
    'invalid_payment_method',
  );

  /// 3-D Secure authentication failed or was abandoned.
  static const UqpayErrorCode threeDsFailed = UqpayErrorCode._('3ds_failed');

  /// The intent or attempt was cancelled.
  static const UqpayErrorCode cancelled = UqpayErrorCode._('cancelled');

  // ---- Auth / configuration -----------------------------------------------

  /// The auth token was rejected (HTTP 401/403), even after one refresh.
  static const UqpayErrorCode authenticationFailed = UqpayErrorCode._(
    'authentication_failed',
  );

  /// The SDK was misconfigured (this is also thrown as an [ArgumentError] at
  /// configuration time; it appears here only for completeness of results).
  static const UqpayErrorCode invalidConfiguration = UqpayErrorCode._(
    'invalid_configuration',
  );

  // ---- Transport (each distinct) -------------------------------------------

  /// A socket-level failure: connection refused/reset, no route, offline.
  static const UqpayErrorCode networkError = UqpayErrorCode._('network_error');

  /// The host name could not be resolved.
  static const UqpayErrorCode dnsFailure = UqpayErrorCode._('dns_failure');

  /// The request or a poll budget timed out. The payment may still be live.
  static const UqpayErrorCode timeout = UqpayErrorCode._('timeout');

  /// The TLS handshake failed (bad certificate, protocol mismatch).
  static const UqpayErrorCode tlsFailure = UqpayErrorCode._('tls_failure');

  /// The server answered 5xx. Outcome unknown; safe to retry with the same
  /// idempotency key.
  static const UqpayErrorCode serverError = UqpayErrorCode._('server_error');

  /// The server answered 429. Outcome unknown; retry later with the same
  /// idempotency key.
  static const UqpayErrorCode rateLimited = UqpayErrorCode._('rate_limited');

  /// A 2xx response whose body could not be parsed. The request **was**
  /// processed — reconcile, never retry blindly.
  static const UqpayErrorCode malformedResponse = UqpayErrorCode._(
    'malformed_response',
  );

  /// No more specific classification was possible.
  static const UqpayErrorCode unknown = UqpayErrorCode._('unknown');

  /// Every code the SDK recognises. [unknown] is listed but still reports
  /// [isUnknown] `true`.
  static const List<UqpayErrorCode> known = <UqpayErrorCode>[
    cardDeclined,
    insufficientFunds,
    invalidPaymentMethod,
    threeDsFailed,
    cancelled,
    authenticationFailed,
    invalidConfiguration,
    networkError,
    dnsFailure,
    timeout,
    tlsFailure,
    serverError,
    rateLimited,
    malformedResponse,
    unknown,
  ];

  /// The code string, e.g. `card_declined`, or the verbatim server code when
  /// unrecognised.
  final String raw;

  /// `true` for [unknown] and for any code the SDK does not recognise. An
  /// unknown code is never a success and never retried automatically.
  bool get isUnknown => this == unknown || !known.contains(this);

  @override
  bool operator ==(Object other) => other is UqpayErrorCode && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UqpayErrorCode($raw)';
}
