import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/core/canonical_json.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/core/uuid.dart';

void main() {
  group('encodeCanonicalJson', () {
    test('sorts keys at every level, including inside lists', () {
      final a = <String, Object?>{
        'z': 1,
        'a': <String, Object?>{'y': true, 'b': null},
        'm': <Object?>[
          <String, Object?>{'q': 'x', 'c': 2},
          'str',
        ],
      };
      final b = <String, Object?>{
        'm': <Object?>[
          <String, Object?>{'c': 2, 'q': 'x'},
          'str',
        ],
        'a': <String, Object?>{'b': null, 'y': true},
        'z': 1,
      };
      expect(encodeCanonicalJson(a), encodeCanonicalJson(b));
      expect(
        encodeCanonicalJson(a),
        '{"a":{"b":null,"y":true},"m":[{"c":2,"q":"x"},"str"],"z":1}',
      );
    });

    test('is byte-stable across a decode/re-encode cycle', () {
      const wire =
          '{"amount":"8.98","payment_method":{"card":{"cvc":"123"},'
          '"type":"card"}}';
      final decoded = jsonDecode(wire) as Map<String, Object?>;
      expect(encodeCanonicalJson(decoded), wire);
    });

    test('rejects doubles and non-JSON values', () {
      expect(
        () => encodeCanonicalJson(<String, Object?>{'a': 1.5}),
        throwsArgumentError,
      );
      expect(
        () => encodeCanonicalJson(<String, Object?>{'a': DateTime.utc(2026)}),
        throwsArgumentError,
      );
    });

    test('accepts scalars', () {
      expect(encodeCanonicalJson(null), 'null');
      expect(encodeCanonicalJson('s'), '"s"');
      expect(encodeCanonicalJson(3), '3');
      expect(encodeCanonicalJson(true), 'true');
    });
  });

  group('generateUuidV4', () {
    test('produces lowercase canonical v4 UUIDs', () {
      for (var i = 0; i < 200; i++) {
        final uuid = generateUuidV4();
        expect(uuid, matches(lowercaseUuidV4Pattern));
        expect(uuid, uuid.toLowerCase());
        expect(uuid.length, 36);
      }
    });

    test('is deterministic for a seeded generator and unique otherwise', () {
      expect(
        generateUuidV4(random: Random(1)),
        generateUuidV4(random: Random(1)),
      );
      final many = <String>{for (var i = 0; i < 1000; i++) generateUuidV4()};
      expect(many, hasLength(1000));
    });

    test(
      'sets version and variant bits even for all-0xff / all-0x00 bytes',
      () {
        final allOnes = generateUuidV4(random: _ConstantRandom(255));
        expect(allOnes, matches(lowercaseUuidV4Pattern));
        expect(allOnes, 'ffffffff-ffff-4fff-bfff-ffffffffffff');
        final allZeros = generateUuidV4(random: _ConstantRandom(0));
        expect(allZeros, '00000000-0000-4000-8000-000000000000');
      },
    );
  });

  group('SystemUqpayClock', () {
    test('elapsed is monotonic and delay completes', () async {
      final clock = SystemUqpayClock();
      final before = clock.elapsed;
      await clock.delay(const Duration(milliseconds: 5));
      expect(clock.elapsed, greaterThanOrEqualTo(before));
      expect(clock.now().isUtc, isTrue);
    });
  });
}

class _ConstantRandom implements Random {
  _ConstantRandom(this.value);
  final int value;

  @override
  bool nextBool() => value != 0;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => value % max;
}
