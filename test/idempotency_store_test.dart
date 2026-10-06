import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/core/uuid.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';

import 'support/fakes.dart';

void main() {
  late InMemoryKeyValueStore storage;
  late FakeClock clock;

  setUp(() {
    storage = InMemoryKeyValueStore();
    clock = FakeClock();
  });

  IdempotencyStore store({String namespace = 'sandbox|https://a|m1'}) =>
      IdempotencyStore(storage: storage, clock: clock, namespace: namespace);

  Map<String, Object?> body({String pan = testPan, String amount = '8.98'}) =>
      cardConfirmRequest(cardNumber: pan).toJson()..['amount'] = amount;

  group('IdempotencyStore.obtain', () {
    test(
      'mints a lowercase UUID v4 and persists it before returning',
      () async {
        final pin = await store().obtain(intentId: 'pi_1', body: body());

        expect(pin.key, matches(lowercaseUuidV4Pattern));
        expect(pin.intentId, 'pi_1');
        expect(pin.namespace, 'sandbox|https://a|m1');
        expect(pin.createdAt, clock.now());
        expect(storage.entries, hasLength(1));
        final stored = storage.entries.values.single;
        expect(stored, contains(pin.key));
        expect(
          storage.entries.keys.single,
          startsWith(IdempotencyStore.keyPrefix),
        );
        expect(pin.toString(), contains(pin.key));
      },
    );

    test('nothing PAN- or CVC-derived is at rest', () async {
      await store().obtain(intentId: 'pi_1', body: body());
      final everything = storage.entries.entries
          .map((e) => '${e.key}=${e.value}')
          .join();
      expect(everything, isNot(contains(testPan)));
      expect(everything, isNot(contains(testCvc)));
      expect(everything, isNot(contains('Ada')));
      // Not even a hash of the full body: the fingerprint of two bodies that
      // differ only in CVC or in the middle PAN digits (the digits between the
      // BIN and the last four) is identical.
      expect(
        IdempotencyStore.fingerprintFor(body()),
        IdempotencyStore.fingerprintFor(
          cardConfirmRequest(cvc: '999').toJson()..['amount'] = '8.98',
        ),
      );
      expect(
        IdempotencyStore.fingerprintFor(body()),
        IdempotencyStore.fingerprintFor(body(pan: '4242420000004242')),
      );
    });
  });

  group('IdempotencyStore reuse vs. new attempt', () {
    test('the same logical attempt reuses the same key', () async {
      final s = store();
      final first = await s.obtain(intentId: 'pi_1', body: body());
      final again = await s.obtain(intentId: 'pi_1', body: body());
      expect(again.key, first.key);
      expect(again, first);
      expect(again.hashCode, first.hashCode);
      expect(storage.entries, hasLength(1));
      // A fresh store instance over the same storage (process restart)
      // finds the same pin.
      final restarted = await store().obtain(intentId: 'pi_1', body: body());
      expect(restarted.key, first.key);
    });

    test('a changed card or amount gets a new key', () async {
      final s = store();
      final base = await s.obtain(intentId: 'pi_1', body: body());
      final otherCard = await s.obtain(
        intentId: 'pi_1',
        body: body(pan: '5555555555554444'),
      );
      final otherAmount = await s.obtain(
        intentId: 'pi_1',
        body: body(amount: '9.98'),
      );
      final otherIntent = await s.obtain(intentId: 'pi_2', body: body());
      final keys = {base.key, otherCard.key, otherAmount.key, otherIntent.key};
      expect(keys, hasLength(4));
      expect(storage.entries, hasLength(4));
    });

    test('fingerprints are stable across map insertion order', () {
      final a = <String, Object?>{
        'b': 1,
        'a': <String, Object?>{'y': 2, 'x': 3},
      };
      final b = <String, Object?>{
        'a': <String, Object?>{'x': 3, 'y': 2},
        'b': 1,
      };
      expect(
        IdempotencyStore.fingerprintFor(a),
        IdempotencyStore.fingerprintFor(b),
      );
      expect(IdempotencyStore.fingerprintFor(a), hasLength(16));
      // Redaction handles lists and short card_number values too.
      final weird = <String, Object?>{
        'list': <Object?>[
          <String, Object?>{'card_number': '1234', 'cvc': 'x'},
          'plain',
        ],
        'card_number': 12,
      };
      expect(IdempotencyStore.fingerprintFor(weird), hasLength(16));
    });
  });

  group('IdempotencyStore namespaces, expiry, cleanup', () {
    test('pins are namespaced per environment + merchant', () async {
      final sandbox = store();
      final production = store(namespace: 'production|https://b|m1');
      final otherMerchant = store(namespace: 'sandbox|https://a|m2');

      final a = await sandbox.obtain(intentId: 'pi_1', body: body());
      final b = await production.obtain(intentId: 'pi_1', body: body());
      final c = await otherMerchant.obtain(intentId: 'pi_1', body: body());

      expect({a.key, b.key, c.key}, hasLength(3));
      expect((await sandbox.unresolved()).map((p) => p.key), [a.key]);
      expect((await production.unresolved()).map((p) => p.key), [b.key]);
      expect((await otherMerchant.unresolved()).map((p) => p.key), [c.key]);
      expect(
        IdempotencyStore.namespaceFor(
          environment: 'sandbox',
          baseUrl: 'https://x',
        ),
        'sandbox|https://x|default',
      );
      expect(
        IdempotencyStore.namespaceFor(
          environment: 'sandbox',
          baseUrl: 'https://x',
          merchant: 'm',
        ),
        'sandbox|https://x|m',
      );
    });

    test('a pin expires after 24 h and a new key is minted', () async {
      final s = store();
      final first = await s.obtain(intentId: 'pi_1', body: body());
      clock.advance(const Duration(hours: 23, minutes: 59));
      expect((await s.obtain(intentId: 'pi_1', body: body())).key, first.key);
      clock.advance(const Duration(minutes: 1));
      final fresh = await s.obtain(intentId: 'pi_1', body: body());
      expect(fresh.key, isNot(first.key));
      expect(storage.entries, hasLength(1), reason: 'expired pin replaced');
    });

    test('expiry uses the wall clock so it survives a restart', () async {
      final s = store();
      final first = await s.obtain(intentId: 'pi_1', body: body());
      // Simulate a restart: monotonic time resets, wall clock moved on.
      clock.advanceWallClockOnly(const Duration(hours: 25));
      final fresh = await s.obtain(intentId: 'pi_1', body: body());
      expect(fresh.key, isNot(first.key));
    });

    test('release removes the pin; idempotent', () async {
      final s = store();
      final pin = await s.obtain(intentId: 'pi_1', body: body());
      await s.release(intentId: 'pi_1', fingerprint: pin.fingerprint);
      await s.release(intentId: 'pi_1', fingerprint: pin.fingerprint);
      expect(storage.entries, isEmpty);
      expect(
        await s.find(intentId: 'pi_1', fingerprint: pin.fingerprint),
        isNull,
      );
      final next = await s.obtain(intentId: 'pi_1', body: body());
      expect(next.key, isNot(pin.key));
    });

    test('unresolved lists live pins and purges expired ones', () async {
      final s = store();
      final old = await s.obtain(intentId: 'pi_old', body: body());
      clock.advance(const Duration(hours: 12));
      final young = await s.obtain(intentId: 'pi_young', body: body());
      clock.advance(const Duration(hours: 12, seconds: 1));

      final live = await s.unresolved();
      expect(live.map((p) => p.key), [young.key]);
      expect(storage.entries, hasLength(1));
      expect(live.single, isNot(old));
    });

    test(
      'purgeExpired sweeps every namespace and drops corrupt records',
      () async {
        final a = store(namespace: 'a');
        final b = store(namespace: 'b');
        final aOld = await a.obtain(intentId: 'pi_1', body: body());
        clock.advance(const Duration(hours: 25));
        final bYoung = await b.obtain(intentId: 'pi_1', body: body());
        await storage.write('${IdempotencyStore.keyPrefix}junk', 'not json');
        await storage.write('${IdempotencyStore.keyPrefix}junk2', '[1]');
        await storage.write(
          '${IdempotencyStore.keyPrefix}junk3',
          jsonEncode({'namespace': 'x'}),
        );
        await storage.write('unrelated', 'keep me');

        await a.purgeExpired();

        expect(storage.entries.keys, isNot(contains(contains(aOld.key))));
        expect(storage.entries.values, contains(contains(bYoung.key)));
        expect(storage.entries, hasLength(2));
        expect(storage.entries['unrelated'], 'keep me');
      },
    );

    test('a corrupt pin under a live key is treated as absent', () async {
      final s = store();
      final pin = await s.obtain(intentId: 'pi_1', body: body());
      final storageKey = storage.entries.keys.single;
      await storage.write(storageKey, '{"key": 1}');
      expect(
        await s.find(intentId: 'pi_1', fingerprint: pin.fingerprint),
        isNull,
      );
      final fresh = await s.obtain(intentId: 'pi_1', body: body());
      expect(fresh.key, isNot(pin.key));
    });

    test('a wall clock that went backwards treats the pin as fresh', () async {
      final s = store();
      final pin = await s.obtain(intentId: 'pi_1', body: body());
      clock.advanceWallClockOnly(const Duration(hours: -5));
      expect((await s.obtain(intentId: 'pi_1', body: body())).key, pin.key);
    });
  });

  group('IdempotencyPin', () {
    test('json round-trip and equality', () {
      final pin = IdempotencyPin(
        namespace: 'n',
        intentId: 'i',
        fingerprint: 'f',
        key: 'k',
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final decoded = IdempotencyPin.fromJson(pin.toJson());
      expect(decoded, pin);
      expect(decoded.hashCode, pin.hashCode);
      expect(decoded.createdAt.isUtc, isTrue);
      expect(
        pin,
        isNot(
          IdempotencyPin(
            namespace: 'n',
            intentId: 'i',
            fingerprint: 'f',
            key: 'other',
            createdAt: pin.createdAt,
          ),
        ),
      );
      expect(
        () => IdempotencyPin.fromJson(const {'namespace': 'n'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('KeyValueStore fakes', () {
    test('InMemoryKeyValueStore basics', () async {
      final kv = InMemoryKeyValueStore();
      await kv.write('a.1', 'x');
      await kv.write('a.2', 'y');
      await kv.write('b.1', 'z');
      expect(await kv.read('a.1'), 'x');
      expect(await kv.read('nope'), isNull);
      expect(await kv.keysWithPrefix('a.'), {'a.1', 'a.2'});
      await kv.remove('a.1');
      expect(await kv.read('a.1'), isNull);
      expect(() => kv.entries['q'] = 'w', throwsUnsupportedError);
    });
  });
}
