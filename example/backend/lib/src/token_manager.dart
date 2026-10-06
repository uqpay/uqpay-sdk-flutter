/// Server-side owner of the UQPAY auth token.
///
/// UQPAY permits ONE active token per merchant: issuing a new token silently
/// invalidates the previous one. That is why this
/// class — and nothing else in the merchant's estate — calls
/// `POST /api/v1/connect/token`, and why concurrent callers share a single
/// in-flight fetch instead of racing to mint two tokens.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// A minted token plus its absolute expiry.
class AuthToken {
  AuthToken({required this.value, required this.expiresAt});

  final String value;
  final DateTime expiresAt;

  /// True when the token should no longer be handed out. Uses the same
  /// 120-second refresh margin as the iOS credential provider.
  bool isFresh(DateTime now, {Duration margin = TokenManager.refreshMargin}) =>
      now.add(margin).isBefore(expiresAt);
}

/// Raised when UQPAY refuses to issue a token.
class TokenIssueException implements Exception {
  TokenIssueException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'TokenIssueException($statusCode): $message';
}

class TokenManager {
  TokenManager({
    required BackendConfig config,
    required http.Client client,
    DateTime Function()? clock,
    void Function(String line)? log,
  }) : _config = config,
       _client = client,
       _clock = clock ?? DateTime.now,
       _log = log ?? ((_) {});

  /// Refresh this long before expiry.
  static const Duration refreshMargin = Duration(seconds: 120);

  /// Assumed lifetime when the response omits `expired_at`. Deliberately shorter than UQPAY's 30 minutes.
  static const Duration assumedLifetime = Duration(minutes: 20);

  /// At most one caller-forced re-issue per this window. Every mint kills the
  /// merchant's only token, and the four-character suffix that forces one is
  /// known to anyone holding the token, so without a limit a single caller
  /// could keep every checkout failing with `authentication_failed`.
  static const Duration forcedMintInterval = Duration(seconds: 30);

  final BackendConfig _config;
  final http.Client _client;
  final DateTime Function() _clock;
  final void Function(String line) _log;

  AuthToken? _cached;
  Future<AuthToken>? _inFlight;
  int _issueCount = 0;
  DateTime? _lastForcedMint;

  /// Number of upstream token requests made so far (for tests/diagnostics).
  int get issueCount => _issueCount;

  /// The current token if it is still fresh, otherwise null. Never fetches.
  AuthToken? get cached {
    final t = _cached;
    if (t != null && t.isFresh(_clock())) return t;
    return null;
  }

  /// Returns a fresh token, minting one only when needed. Concurrent callers
  /// during a fetch all receive the same future (single-flight).
  ///
  /// [rejectedTokenSuffix] is the last four characters of a token the caller
  /// was refused with. When it matches the cached token, that token has been
  /// invalidated elsewhere (UQPAY keeps one active token per merchant) and
  /// handing it out again would only produce another 401, so the cache is
  /// dropped and a fresh token minted — through the same single-flight path
  /// as the 401 retry, so a burst of rejected callers costs one upstream
  /// call. A suffix that does not match is ignored: the cache has already
  /// moved past the token the caller is complaining about.
  ///
  /// Forced re-issues are rate-limited to one per [forcedMintInterval]; a
  /// report inside the window gets the cached token back.
  Future<AuthToken> getToken({String? rejectedTokenSuffix}) {
    if (rejectedTokenSuffix != null && isCachedToken(rejectedTokenSuffix)) {
      final now = _clock();
      final last = _lastForcedMint;
      if (last != null && now.difference(last) < forcedMintInterval) {
        _log(
          'token: ****$rejectedTokenSuffix reported rejected, but a forced '
          're-issue ran ${now.difference(last).inSeconds}s ago; returning the '
          'cached token (limit: one per ${forcedMintInterval.inSeconds}s)',
        );
      } else {
        _lastForcedMint = now;
        _log('token: ****$rejectedTokenSuffix reported rejected, re-issuing');
        invalidate();
      }
    }
    final fresh = cached;
    if (fresh != null) return Future.value(fresh);
    return _inFlight ??= _issue().whenComplete(() => _inFlight = null);
  }

  /// True when [suffix] is exactly the last four characters of the cached
  /// token. Exactly four, never empty, so a caller cannot force a mint on
  /// every request by sending `""` (which every string ends with).
  bool isCachedToken(String suffix) {
    final t = _cached;
    return t != null &&
        suffix.length == 4 &&
        t.value.length > 4 &&
        t.value.endsWith(suffix);
  }

  /// Drops the cached token so the next [getToken] mints a new one. Called
  /// after an upstream 401 (token expired or was invalidated by another
  /// issuer).
  void invalidate() {
    _cached = null;
  }

  Future<AuthToken> _issue() async {
    final uri = _config.apiBaseUrl.resolve('/api/v1/connect/token');
    _issueCount++;
    _log(
      'token: issuing (client ${mask(_config.clientId)}, '
      'key ${mask(_config.apiKey)})',
    );
    // POST, headers x-client-id + x-api-key, no body.
    final response = await _client.post(
      uri,
      headers: {
        'x-client-id': _config.clientId,
        'x-api-key': _config.apiKey,
        'Accept': 'application/json',
      },
    );
    if (response.statusCode != 200) {
      throw TokenIssueException(
        response.statusCode,
        _errorMessage(response.body),
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw TokenIssueException(200, 'token response was not JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw TokenIssueException(200, 'token response was not a JSON object');
    }
    final value = decoded['auth_token'];
    if (value is! String || value.isEmpty) {
      throw TokenIssueException(200, 'token response lacked auth_token');
    }
    final now = _clock();
    // `expired_at` is a NUMBER of Unix epoch seconds, optional in
    // practice. Tolerate a numeric string too, to be lenient about how the
    // number is encoded.
    final expiredAtRaw = decoded['expired_at'];
    final num? expiredAt = switch (expiredAtRaw) {
      num n => n,
      String s => num.tryParse(s),
      _ => null,
    };
    final expiresAt = expiredAt == null
        ? now.add(assumedLifetime)
        : DateTime.fromMillisecondsSinceEpoch(
            (expiredAt * 1000).round(),
            isUtc: true,
          );
    final token = AuthToken(value: value, expiresAt: expiresAt);
    _cached = token;
    _log(
      'token: issued ${mask(value)}, expires ${expiresAt.toIso8601String()}',
    );
    return token;
  }

  static String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final message = decoded['message'];
        final code = decoded['code'];
        if (message is String && message.isNotEmpty) return message;
        if (code is String && code.isNotEmpty) return code;
      }
    } on FormatException {
      // fall through
    }
    final oneLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 300 ? oneLine.substring(0, 300) : oneLine;
  }
}
