import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/core/canonical_json.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/core/uuid.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';

/// A persisted idempotency pin: one `x-idempotency-key` for one logical
/// payment attempt.
///
/// A pin holds **no request body** — the body of a card confirm contains the
/// PAN and nothing PAN-derived may be at rest. [fingerprint] is a
/// digest of the body with the card number reduced to its last four digits
/// and the CVC removed, which is enough to tell "same logical attempt" from
/// "new card / new amount".
@immutable
class IdempotencyPin {
  /// Creates a pin.
  const IdempotencyPin({
    required this.namespace,
    required this.intentId,
    required this.fingerprint,
    required this.key,
    required this.createdAt,
    this.ipAddress,
  });

  /// Decodes a stored pin. Throws [FormatException] on a corrupt record.
  factory IdempotencyPin.fromJson(Map<String, Object?> json) {
    final namespace = json['namespace'];
    final intentId = json['intent_id'];
    final fingerprint = json['fingerprint'];
    final key = json['key'];
    final createdAt = json['created_at'];
    if (namespace is! String ||
        intentId is! String ||
        fingerprint is! String ||
        key is! String ||
        createdAt is! int) {
      throw const FormatException('corrupt idempotency pin');
    }
    final ipAddress = json['ip_address'];
    return IdempotencyPin(
      ipAddress: ipAddress is String && ipAddress.isNotEmpty ? ipAddress : null,
      namespace: namespace,
      intentId: intentId,
      fingerprint: fingerprint,
      key: key,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
    );
  }

  /// `environment + merchant` scope.
  final String namespace;

  /// The intent this attempt pays.
  final String intentId;

  /// Digest of the redacted confirm body.
  final String fingerprint;

  /// The lowercase UUID v4 sent as `x-idempotency-key`.
  final String key;

  /// When the pin was minted (UTC wall clock — must survive restarts).
  final DateTime createdAt;

  /// The device IP the SDK resolved for the first send, replayed verbatim on
  /// a retry so the body stays byte-identical even after a network change.
  /// `null` for a caller-supplied address (part of the fingerprint instead).
  final String? ipAddress;

  /// The wire representation.
  Map<String, Object?> toJson() => <String, Object?>{
    'namespace': namespace,
    'intent_id': intentId,
    'fingerprint': fingerprint,
    'key': key,
    'created_at': createdAt.millisecondsSinceEpoch,
    if (ipAddress != null) 'ip_address': ipAddress,
  };

  @override
  bool operator ==(Object other) =>
      other is IdempotencyPin &&
      other.namespace == namespace &&
      other.intentId == intentId &&
      other.fingerprint == fingerprint &&
      other.key == key &&
      other.createdAt == createdAt;

  @override
  int get hashCode =>
      Object.hash(namespace, intentId, fingerprint, key, createdAt);

  @override
  String toString() =>
      'IdempotencyPin(intent: $intentId, key: $key, createdAt: $createdAt)';
}

/// Mints, persists, looks up and expires idempotency pins.
///
/// * A key is a lowercase UUID v4, generated in-house.
/// * [obtain] **persists the pin before returning**, so the key is on disk
///   before the confirm request leaves the device.
/// * Pins are namespaced by environment + merchant, expire after
///   [ttl] (24 h) on the injected clock, and are removed by [release] on
///   terminal resolution — no unbounded growth.
class IdempotencyStore {
  /// Creates a store over [storage], scoped to [namespace].
  IdempotencyStore({
    required KeyValueStore storage,
    required UqpayClock clock,
    required this.namespace,
  }) : _storage = storage,
       _clock = clock;

  /// Server replay window; pins older than this are useless and purged.
  static const Duration ttl = Duration(hours: 24);

  /// Storage key prefix shared by every pin of every namespace.
  static const String keyPrefix = 'uqpay.idem.';

  final KeyValueStore _storage;
  final UqpayClock _clock;

  /// `environment + merchant` scope this store reads and writes.
  final String namespace;

  /// Builds a namespace string. [merchant] is the merchant/client id when
  /// configured, otherwise a constant.
  static String namespaceFor({
    required String environment,
    required String baseUrl,
    String? merchant,
  }) => '$environment|$baseUrl|${merchant ?? 'default'}';

  String _storageKey(String intentId, String fingerprint) =>
      '$keyPrefix${base64Url.encode(utf8.encode(namespace))}'
      '.${base64Url.encode(utf8.encode(intentId))}.$fingerprint';

  /// Returns the pin for this logical attempt, minting and persisting a new
  /// one when none exists or the existing one has expired.
  ///
  /// The returned pin is guaranteed to be durably stored when the future
  /// completes.
  Future<IdempotencyPin> obtain({
    required String intentId,
    required Map<String, Object?> body,
    String? ipAddress,
  }) async => (await obtainOrReuse(
    intentId: intentId,
    body: body,
    ipAddress: ipAddress,
  )).pin;

  /// Per-intent serialisation of [obtainOrReuse]: two flows for the same
  /// intent started in the same tick must come out holding ONE pin, never
  /// two keys for one logical attempt.
  final Map<String, Future<void>> _obtainLocks = <String, Future<void>>{};

  /// Like [obtain], and also says whether the pin was minted by this call
  /// (`created`) or found from an earlier attempt. Only the creator may
  /// release it.
  Future<({IdempotencyPin pin, bool created})> obtainOrReuse({
    required String intentId,
    required Map<String, Object?> body,
    String? ipAddress,
  }) async {
    final previous = _obtainLocks[intentId] ?? Future<void>.value();
    final completer = Completer<void>();
    _obtainLocks[intentId] = completer.future;
    try {
      await previous;
      return await _obtainLocked(
        intentId: intentId,
        body: body,
        ipAddress: ipAddress,
      );
    } finally {
      completer.complete();
      if (identical(_obtainLocks[intentId], completer.future)) {
        _obtainLocks.remove(intentId)?.ignore();
      }
    }
  }

  Future<({IdempotencyPin pin, bool created})> _obtainLocked({
    required String intentId,
    required Map<String, Object?> body,
    String? ipAddress,
  }) async {
    final fingerprint = fingerprintFor(body);
    final existing = await find(intentId: intentId, fingerprint: fingerprint);
    if (existing != null) {
      return (pin: existing, created: false);
    }
    final pin = IdempotencyPin(
      namespace: namespace,
      intentId: intentId,
      fingerprint: fingerprint,
      key: generateUuidV4(),
      createdAt: _clock.now(),
      ipAddress: ipAddress,
    );
    await _storage.write(
      _storageKey(intentId, fingerprint),
      encodeCanonicalJson(pin.toJson()),
    );
    return (pin: pin, created: true);
  }

  /// Looks up an unexpired pin, or `null`. Expired or corrupt pins are
  /// removed on the way.
  Future<IdempotencyPin?> find({
    required String intentId,
    required String fingerprint,
  }) async {
    final storageKey = _storageKey(intentId, fingerprint);
    final pin = await _decode(storageKey);
    if (pin == null) {
      return null;
    }
    if (_isExpired(pin)) {
      await _storage.remove(storageKey);
      return null;
    }
    return pin;
  }

  /// Removes the pin for a resolved attempt. Idempotent.
  Future<void> release({
    required String intentId,
    required String fingerprint,
  }) => _storage.remove(_storageKey(intentId, fingerprint));

  /// All unexpired pins in this namespace — the unresolved attempts a
  /// launch-time reconcile must look at. Expired pins are purged.
  Future<List<IdempotencyPin>> unresolved() async {
    final prefix = '$keyPrefix${base64Url.encode(utf8.encode(namespace))}.';
    final pins = <IdempotencyPin>[];
    for (final storageKey in await _storage.keysWithPrefix(prefix)) {
      final pin = await _decode(storageKey);
      if (pin == null || _isExpired(pin)) {
        await _storage.remove(storageKey);
        continue;
      }
      pins.add(pin);
    }
    return pins;
  }

  /// Removes every expired or corrupt pin in **every** namespace.
  Future<void> purgeExpired() async {
    for (final storageKey in await _storage.keysWithPrefix(keyPrefix)) {
      final pin = await _decode(storageKey);
      if (pin == null || _isExpired(pin)) {
        await _storage.remove(storageKey);
      }
    }
  }

  bool _isExpired(IdempotencyPin pin) {
    final age = _clock.now().difference(pin.createdAt);
    // A negative age means the wall clock went backwards; treat as fresh.
    return age >= ttl;
  }

  Future<IdempotencyPin?> _decode(String storageKey) async {
    final raw = await _storage.read(storageKey);
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return IdempotencyPin.fromJson(decoded);
    } on Object {
      // Corrupt in any way (bad JSON, out-of-range timestamp, wrong types):
      // one bad record must never take the whole store down.
      return null;
    }
  }

  /// A digest of [body] that identifies the *logical* attempt without being
  /// derived from the PAN or CVC: every `card_number` value is reduced to its
  /// first six and last four digits, every `cvc` value is dropped, and the
  /// top-level `browser_info` snapshot is ignored before hashing the
  /// canonical JSON. The snapshot carries a per-session random
  /// `device_id`, so including it would give every new sheet session — every
  /// retry after a process death included — a fresh key. Same
  /// payment method → same fingerprint; a different card → a different one.
  static String fingerprintFor(Map<String, Object?> body) {
    final redacted = _redact(body, topLevel: true)! as Map<String, Object?>;
    return _fnv1a64Hex(utf8.encode(encodeCanonicalJson(redacted)));
  }

  static Object? _redact(Object? value, {bool topLevel = false}) {
    if (value is Map<Object?, Object?>) {
      return <String, Object?>{
        for (final entry in value.entries)
          if (entry.key != 'cvc' && !(topLevel && entry.key == 'browser_info'))
            entry.key! as String: entry.key == 'card_number'
                ? _first6Last4(entry.value)
                : _redact(entry.value),
      };
    }
    if (value is List<Object?>) {
      return value.map(_redact).toList(growable: false);
    }
    return value;
  }

  static Object? _first6Last4(Object? value) {
    if (value is String && value.length > 10) {
      return '${value.substring(0, 6)}${value.substring(value.length - 4)}';
    }
    return value;
  }

  /// 64-bit FNV-1a, hex encoded. Non-cryptographic; it only has to make two
  /// different logical attempts land on different keys locally.
  static String _fnv1a64Hex(List<int> bytes) {
    // BigInt keeps the arithmetic identical on the web (no 64-bit ints).
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    for (final byte in bytes) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
