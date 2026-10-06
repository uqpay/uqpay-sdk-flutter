import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';

/// A minimal durable string store — the SDK's only persistence seam.
///
/// Production uses [SharedPreferencesKeyValueStore]; tests use an in-memory
/// implementation. Keeping the seam this narrow makes the at-rest audit ("what
/// does the SDK ever write to disk?") a review of one interface.
abstract interface class KeyValueStore {
  /// Reads the value under [key], or `null`.
  Future<String?> read(String key);

  /// Writes [value] under [key], durably, before completing.
  Future<void> write(String key, String value);

  /// Removes [key]. Idempotent.
  Future<void> remove(String key);

  /// All keys currently stored that start with [prefix].
  Future<Set<String>> keysWithPrefix(String prefix);
}

/// [KeyValueStore] over `shared_preferences` (`localStorage` on web).
///
/// Uses [SharedPreferencesAsync] so every write goes straight to the platform
/// store rather than a memory cache — a pin must be on disk before the
/// confirm request leaves the device.
class SharedPreferencesKeyValueStore implements KeyValueStore {
  /// Creates a store. [preferences] is injectable for tests. The platform
  /// store is not touched until the first read or write.
  SharedPreferencesKeyValueStore({SharedPreferencesAsync? preferences})
    : _injected = preferences;

  final SharedPreferencesAsync? _injected;
  late final SharedPreferencesAsync _preferences =
      _injected ?? SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> remove(String key) => _preferences.remove(key);

  @override
  Future<Set<String>> keysWithPrefix(String prefix) async {
    final keys = await _preferences.getKeys();
    return keys.where((k) => k.startsWith(prefix)).toSet();
  }
}

/// In-memory [KeyValueStore] for tests and for platforms where persistence
/// is unavailable. Not durable.
class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _data = <String, String>{};

  /// A read-only view of the stored entries (for test assertions).
  Map<String, String> get entries => Map<String, String>.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> remove(String key) async => _data.remove(key);

  @override
  Future<Set<String>> keysWithPrefix(String prefix) async =>
      _data.keys.where((k) => k.startsWith(prefix)).toSet();
}

/// Bounds every call to an inner [KeyValueStore] with [bound] on the SDK
/// clock: a platform channel that never answers must not
/// hold the merchant's payment future hostage. A call that overruns throws
/// [TimeoutException]; the flow then treats it as a storage failure (nothing
/// sent, retryable) or, after the fact, as a best-effort release that is
/// simply skipped.
class BoundedKeyValueStore implements KeyValueStore {
  /// Wraps [inner]; calls longer than [bound] fail.
  BoundedKeyValueStore(
    this.inner, {
    required UqpayClock clock,
    this.bound = defaultBound,
  }) : _clock = clock;

  /// The default bound: generous for a healthy device, short enough that a
  /// wedged platform channel costs a payment seconds, not forever.
  static const Duration defaultBound = Duration(seconds: 5);

  /// The wrapped store.
  final KeyValueStore inner;

  /// The maximum time one call may take.
  final Duration bound;

  final UqpayClock _clock;

  Future<T> _bounded<T>(Future<T> Function() call) async {
    final timer = _clock.startDelay(bound);
    try {
      return await Future.any<T>([
        call(),
        timer.future.then(
          (_) => throw TimeoutException(
            'local storage did not respond within ${bound.inSeconds}s',
          ),
        ),
      ]);
    } finally {
      timer.cancel();
    }
  }

  @override
  Future<String?> read(String key) => _bounded(() => inner.read(key));

  @override
  Future<void> write(String key, String value) =>
      _bounded(() => inner.write(key, value));

  @override
  Future<void> remove(String key) => _bounded(() => inner.remove(key));

  @override
  Future<Set<String>> keysWithPrefix(String prefix) =>
      _bounded(() => inner.keysWithPrefix(prefix));
}
