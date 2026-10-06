import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';

/// A short-lived UQPAY auth token obtained from **your backend**.
///
/// The SDK never holds an API key and never calls UQPAY's token endpoint
/// itself: your server calls
/// `POST /api/v1/connect/token` once and hands the resulting `auth_token` to
/// the app through an endpoint you control. Decode that response with
/// [UqpayAuthToken.fromJson] — it accepts the wire shape
/// `{"auth_token": "…", "expired_at": 1765941179}` verbatim.
///
/// [toString] never prints the token.
@immutable
class UqpayAuthToken {
  /// Creates a token. [expiresAt] is optional; when your backend does not
  /// forward `expired_at` the SDK assumes a 20-minute lifetime (shorter than
  /// UQPAY's 30) and refreshes accordingly.
  ///
  /// Throws [ArgumentError] naming `value` when it is empty.
  UqpayAuthToken({required this.value, this.expiresAt}) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value('', 'value', 'auth token must not be empty');
    }
  }

  /// Decodes the token endpoint's JSON: `auth_token` (string, required) and
  /// `expired_at` (**number**, Unix epoch seconds, optional).
  ///
  /// Throws [FormatException] when `auth_token` is missing or empty.
  factory UqpayAuthToken.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final expiredAt = json['expired_at'];
    final seconds = switch (expiredAt) {
      int() => expiredAt,
      // Tolerate a float or a numeric string from a lenient backend.
      double() => expiredAt.floor(),
      String() => int.tryParse(expiredAt),
      _ => null,
    };
    return UqpayAuthToken(
      value: r.requireString('auth_token'),
      expiresAt: seconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    );
  }

  /// The bearer token sent as `x-auth-token: Bearer <value>`.
  final String value;

  /// Absolute expiry (UTC), or `null` when unknown.
  final DateTime? expiresAt;

  @override
  bool operator ==(Object other) =>
      other is UqpayAuthToken &&
      other.value == value &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(value, expiresAt);

  @override
  String toString() =>
      'UqpayAuthToken(value: <redacted>, expiresAt: $expiresAt)';
}

/// Supplies a fresh [UqpayAuthToken] from **your backend** whenever the SDK
/// needs one.
///
/// The SDK calls it lazily, caches the result until shortly before expiry,
/// de-duplicates concurrent calls, and calls it again exactly once when the
/// API answers 401 mid-request. It must complete with a token or throw; a
/// thrown error surfaces as an authentication failure, never as a crash.
///
/// ```dart
/// UqpaySdk.init(
///   environment: UqpayEnvironment.sandbox,
///   tokenProvider: () async {
///     final response = await myBackend.get('/uqpay/token');
///     return UqpayAuthToken.fromJson(response.json);
///   },
/// );
/// ```
typedef UqpayTokenProvider = Future<UqpayAuthToken> Function();
