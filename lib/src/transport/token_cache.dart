import 'dart:async';

import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_token_provider.dart';

/// Caches the merchant's [UqpayTokenProvider] result as the gateway's token
/// rules require.
///
/// * cache until `expiresAt − 120 s`;
/// * when the backend omits `expired_at`, assume a 20-minute lifetime;
/// * single-flight: concurrent callers await one in-flight fetch;
/// * [invalidate] drops the cache so the next call refetches (used exactly
///   once per request on HTTP 401).
///
/// Expiry is measured on the injected clock's **monotonic**
/// [UqpayClock.elapsed] so backgrounding the app never produces a spurious
/// refresh or a stale token; the token's absolute `expiresAt` is converted to
/// a remaining lifetime at fetch time.
class TokenCache {
  /// Creates a cache around [provider].
  TokenCache({required UqpayTokenProvider provider, required UqpayClock clock})
    : _provider = provider,
      _clock = clock;

  /// Refresh this long before the token's stated expiry.
  static const Duration refreshMargin = Duration(seconds: 120);

  /// Assumed lifetime when the backend omits `expired_at`.
  static const Duration assumedLifetime = Duration(minutes: 20);

  /// How long a `tokenProvider` call may take before it is treated as a
  /// failure (same bound as an HTTP request).
  static const Duration providerTimeout = Duration(seconds: 30);

  final UqpayTokenProvider _provider;
  final UqpayClock _clock;

  UqpayAuthToken? _token;
  Duration? _staleAt;
  Future<UqpayAuthToken>? _inFlight;

  /// After a provider failure (throw or timeout), the same failure is
  /// returned without calling the provider again for this long, so one hung
  /// callback costs a payment one timeout, not one per request.
  static const Duration failureCooldown = Duration(seconds: 5);

  Object? _lastFailure;
  Duration? _failedAt;

  /// Returns a usable token, fetching one when the cache is empty or stale.
  Future<UqpayAuthToken> token() {
    final cached = _token;
    if (cached != null && _staleAt != null && _clock.elapsed < _staleAt!) {
      return Future<UqpayAuthToken>.value(cached);
    }
    final failure = _lastFailure;
    final failedAt = _failedAt;
    if (failure != null &&
        failedAt != null &&
        _clock.elapsed - failedAt < failureCooldown) {
      return Future<UqpayAuthToken>.error(failure);
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final fetch = _fetch();
    _inFlight = fetch;
    // Cleared when THIS fetch settles — assigned before any await so a
    // provider that throws synchronously cannot leave a failed future
    // cached forever.
    fetch.whenComplete(() {
      if (identical(_inFlight, fetch)) {
        _inFlight = null;
      }
    }).ignore();
    return fetch;
  }

  Future<UqpayAuthToken> _fetch() async {
    try {
      // A merchant callback that never completes must not hang a payment:
      // bound it like any other request.
      final UqpayAuthToken fetched;
      try {
        fetched = await _provider().timeout(providerTimeout);
      } on Object catch (error) {
        _lastFailure = error;
        _failedAt = _clock.elapsed;
        rethrow;
      }
      _lastFailure = null;
      _failedAt = null;
      final now = _clock.elapsed;
      final expiresAt = fetched.expiresAt;
      var lifetime = expiresAt == null
          ? assumedLifetime
          : expiresAt.difference(_clock.now());
      lifetime -= refreshMargin;
      if (lifetime.isNegative) {
        // Already inside the margin: usable for this request only; the next
        // call refetches.
        lifetime = Duration.zero;
      }
      _token = fetched;
      _staleAt = now + lifetime;
      return fetched;
    } finally {
      // The in-flight slot is cleared by token()'s whenComplete.
    }
  }

  /// Drops the cached token so the next [token] call refetches.
  void invalidate() {
    _token = null;
    _staleAt = null;
  }
}
