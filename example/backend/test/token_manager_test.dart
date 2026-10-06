import 'dart:async';

import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('TokenManager', () {
    test('sends x-client-id + x-api-key with no body', () async {
      final h = Harness();
      await h.tokens.getToken();
      final req = h.upstream.tokenRequests.single;
      expect(req.method, 'POST');
      expect(
        req.url.toString(),
        'https://api-sandbox.uqpaytech.com/api/v1/connect/token',
      );
      expect(req.headers['x-client-id'], testClientId);
      expect(req.headers['x-api-key'], testApiKey);
      expect(req.body, isEmpty);
      expect(req.headers.containsKey('x-auth-token'), isFalse);
    });

    test(
      'single-flight: concurrent callers share one upstream issue',
      () async {
        final h = Harness();
        h.upstream.tokenGate = Completer<void>();

        final futures = List.generate(25, (_) => h.tokens.getToken());
        // All 25 callers are now parked behind one in-flight fetch.
        await Future<void>.delayed(Duration.zero);
        expect(h.upstream.tokenIssues, 1);

        h.upstream.tokenGate!.complete();
        final tokens = await Future.wait(futures);
        expect(tokens.map((t) => t.value).toSet(), {'tok_first_0001'});
        expect(h.upstream.tokenIssues, 1);
        expect(h.tokens.issueCount, 1);
      },
    );

    test(
      'caches until expiry minus the 120 s margin, then re-issues',
      () async {
        final h = Harness();
        final start = h.now;
        h.upstream.expiredAt = start.millisecondsSinceEpoch ~/ 1000 + 1800;

        final first = await h.tokens.getToken();
        expect(first.expiresAt, start.add(const Duration(minutes: 30)));

        h.advance(const Duration(minutes: 27));
        await h.tokens.getToken();
        expect(h.upstream.tokenIssues, 1, reason: 'still inside the window');

        h.advance(const Duration(minutes: 1, seconds: 1)); // 28:01 > 30:00-2:00
        h.upstream.nextToken = 'tok_second_0002';
        final second = await h.tokens.getToken();
        expect(second.value, 'tok_second_0002');
        expect(h.upstream.tokenIssues, 2);
      },
    );

    test('assumes a 20-minute lifetime when expired_at is absent', () async {
      final h = Harness();
      final token = await h.tokens.getToken();
      expect(token.expiresAt, h.now.add(const Duration(minutes: 20)));
    });

    test('accepts expired_at as a numeric string', () async {
      final h = Harness();
      final epoch = h.now.millisecondsSinceEpoch ~/ 1000 + 600;
      h.upstream.expiredAt = '$epoch';
      final token = await h.tokens.getToken();
      expect(token.expiresAt.millisecondsSinceEpoch ~/ 1000, epoch);
    });

    test('invalidate() forces the next call to re-issue', () async {
      final h = Harness();
      await h.tokens.getToken();
      h.tokens.invalidate();
      h.upstream.nextToken = 'tok_third_0003';
      final t = await h.tokens.getToken();
      expect(t.value, 'tok_third_0003');
      expect(h.upstream.tokenIssues, 2);
    });

    test(
      'getToken(rejectedTokenSuffix:) re-issues only on an exact last-4 match',
      () async {
        final h = Harness();
        await h.tokens.getToken();
        expect(h.tokens.isCachedToken('0001'), isTrue);
        expect(h.tokens.isCachedToken('001'), isFalse, reason: 'not 4 chars');
        expect(h.tokens.isCachedToken(''), isFalse, reason: 'never empty');
        expect(h.tokens.isCachedToken('0002'), isFalse);

        final same = await h.tokens.getToken(rejectedTokenSuffix: '0002');
        expect(same.value, 'tok_first_0001');
        expect(h.upstream.tokenIssues, 1);

        h.upstream.nextToken = 'tok_second_0002';
        final fresh = await h.tokens.getToken(rejectedTokenSuffix: '0001');
        expect(fresh.value, 'tok_second_0002');
        expect(h.upstream.tokenIssues, 2);
      },
    );

    test('never logs the raw token or api key', () async {
      final h = Harness();
      await h.tokens.getToken();
      expect(h.logLines, isNotEmpty);
      for (final line in h.logLines) {
        expect(line, isNot(contains(testApiKey)));
        expect(line, isNot(contains('tok_first_0001')));
      }
      expect(h.logLines.join('\n'), contains('****0001'));
      expect(h.logLines.join('\n'), contains('****wxyz'));
    });
  });
}
