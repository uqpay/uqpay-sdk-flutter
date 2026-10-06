import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/transport/token_cache.dart';

import 'support/fakes.dart';

void main() {
  group('UqpayAuthToken', () {
    test('decodes the token endpoint shape', () {
      final token = UqpayAuthToken.fromJson(const {
        'auth_token': 'abc',
        'expired_at': 1765941179,
      });
      expect(token.value, 'abc');
      expect(token.expiresAt, DateTime.utc(2025, 12, 17, 3, 12, 59));
      expect(token.expiresAt!.isUtc, isTrue);
    });

    test('tolerates a missing, float or string expired_at', () {
      expect(
        UqpayAuthToken.fromJson(const {'auth_token': 'a'}).expiresAt,
        isNull,
      );
      expect(
        UqpayAuthToken.fromJson(const {
          'auth_token': 'a',
          'expired_at': 100.9,
        }).expiresAt,
        DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
      );
      expect(
        UqpayAuthToken.fromJson(const {
          'auth_token': 'a',
          'expired_at': '100',
        }).expiresAt,
        DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
      );
      expect(
        UqpayAuthToken.fromJson(const {
          'auth_token': 'a',
          'expired_at': 'soon',
        }).expiresAt,
        isNull,
      );
      expect(
        UqpayAuthToken.fromJson(const {
          'auth_token': 'a',
          'expired_at': true,
        }).expiresAt,
        isNull,
      );
    });

    test('rejects an empty token, naming the field', () {
      expect(
        () => UqpayAuthToken(value: '  '),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'value')),
      );
      expect(
        () => UqpayAuthToken.fromJson(const {'auth_token': ''}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UqpayAuthToken.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
    });

    test('never prints the token; value-equal', () {
      final a = UqpayAuthToken(value: 'secret-token');
      final b = UqpayAuthToken(value: 'secret-token');
      expect(a.toString(), isNot(contains('secret-token')));
      expect(a.toString(), contains('redacted'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(UqpayAuthToken(value: 'other')));
    });
  });

  group('TokenCache', () {
    late FakeClock clock;
    late int calls;
    late List<UqpayAuthToken> queue;

    setUp(() {
      clock = FakeClock();
      calls = 0;
      queue = <UqpayAuthToken>[];
    });

    TokenCache cache() => TokenCache(
      provider: () async {
        calls++;
        return queue.isEmpty
            ? UqpayAuthToken(value: 'tok-$calls')
            : queue.removeAt(0);
      },
      clock: clock,
    );

    test('caches until 120 s before expiry', () async {
      queue.add(
        UqpayAuthToken(
          value: 't1',
          expiresAt: clock.now().add(const Duration(minutes: 30)),
        ),
      );
      final c = cache();
      expect((await c.token()).value, 't1');
      clock.advance(const Duration(minutes: 27, seconds: 59));
      expect((await c.token()).value, 't1');
      expect(calls, 1);
      clock.advance(const Duration(seconds: 2));
      expect((await c.token()).value, 'tok-2');
      expect(calls, 2);
    });

    test('assumes 20 minutes when expiry is absent', () async {
      final c = cache();
      await c.token();
      clock.advance(const Duration(minutes: 17, seconds: 59));
      await c.token();
      expect(calls, 1);
      clock.advance(const Duration(seconds: 2));
      await c.token();
      expect(calls, 2);
    });

    test(
      'a token already inside the margin is used once then refetched',
      () async {
        queue.add(
          UqpayAuthToken(
            value: 'short',
            expiresAt: clock.now().add(const Duration(seconds: 30)),
          ),
        );
        final c = cache();
        expect((await c.token()).value, 'short');
        expect((await c.token()).value, 'tok-2');
      },
    );

    test(
      'measures expiry on the monotonic clock, not the wall clock',
      () async {
        final c = cache();
        await c.token();
        // Device clock jumps forward an hour; monotonic time does not move.
        clock.advanceWallClockOnly(const Duration(hours: 1));
        await c.token();
        expect(calls, 1);
      },
    );

    test('single-flight: concurrent callers share one fetch', () async {
      final completer = Completer<UqpayAuthToken>();
      var fetches = 0;
      final c = TokenCache(
        provider: () {
          fetches++;
          return completer.future;
        },
        clock: clock,
      );
      final futures = [c.token(), c.token(), c.token()];
      expect(fetches, 1);
      completer.complete(UqpayAuthToken(value: 'shared'));
      final tokens = await Future.wait(futures);
      expect(tokens.map((t) => t.value), ['shared', 'shared', 'shared']);
    });

    test('invalidate forces a refetch; a failed fetch is not cached', () async {
      final c = cache();
      expect((await c.token()).value, 'tok-1');
      c.invalidate();
      expect((await c.token()).value, 'tok-2');

      var shouldFail = true;
      final failing = TokenCache(
        provider: () async {
          if (shouldFail) {
            throw Exception('down');
          }
          return UqpayAuthToken(value: 'ok');
        },
        clock: clock,
      );
      await expectLater(failing.token(), throwsException);
      // Within the failure cooldown the same failure is returned without
      // calling the provider again (one hung provider costs one timeout,
      // not one per request); after it, the provider is asked again.
      shouldFail = false;
      await expectLater(failing.token(), throwsException);
      clock.advance(TokenCache.failureCooldown);
      expect((await failing.token()).value, 'ok');
    });
  });
}
