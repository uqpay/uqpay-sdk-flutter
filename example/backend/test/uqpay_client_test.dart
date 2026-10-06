import 'dart:math';

import 'package:test/test.dart';
import 'package:uqpay_reference_backend/uqpay_reference_backend.dart';

import 'helpers.dart';

void main() {
  group('UqpayClient', () {
    test('sends the full header set on create', () async {
      final h = Harness(extraEnv: {'UQPAY_ON_BEHALF_OF': 'acct_sub_1'});
      await h.uqpay.createPaymentIntent('{"amount":"1.00"}');
      final req = h.upstream.intentRequests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/api/v2/payment_intents/create');
      expect(req.headers['x-auth-token'], 'Bearer tok_first_0001');
      expect(req.headers['x-client-id'], testClientId);
      expect(req.headers['x-on-behalf-of'], 'acct_sub_1');
      expect(req.headers['content-type'], startsWith('application/json'));
      expect(
        req.headers.containsKey('x-api-key'),
        isFalse,
        reason: 'the API key is only ever sent to the token endpoint',
      );
      final key = req.headers['x-idempotency-key']!;
      expect(
        key,
        matches(RegExp(r'^[0-9a-f-]{36}$')),
        reason: 'lowercase UUID',
      );
    });

    test('GET carries no idempotency key or body', () async {
      final h = Harness();
      await h.uqpay.getPaymentIntent('pi_123');
      final req = h.upstream.intentRequests.single;
      expect(req.method, 'GET');
      expect(req.url.path, '/api/v2/payment_intents/pi_123');
      expect(req.headers.containsKey('x-idempotency-key'), isFalse);
      expect(req.headers.containsKey('x-on-behalf-of'), isFalse);
      expect(req.body, isEmpty);
    });

    test(
      'on 401: invalidates token, re-issues, retries ONCE with same key',
      () async {
        final h = Harness();
        h.upstream.intentStatuses.add(401);
        await h.tokens.getToken();
        h.upstream.nextToken = 'tok_second_0002';

        final res = await h.uqpay.createPaymentIntent('{"amount":"1.00"}');
        expect(res.statusCode, 200);
        expect(h.upstream.tokenIssues, 2);
        final attempts = h.upstream.intentRequests;
        expect(attempts, hasLength(2));
        expect(attempts[0].headers['x-auth-token'], 'Bearer tok_first_0001');
        expect(attempts[1].headers['x-auth-token'], 'Bearer tok_second_0002');
        expect(
          attempts[0].headers['x-idempotency-key'],
          attempts[1].headers['x-idempotency-key'],
        );
        expect(attempts[0].body, attempts[1].body);
      },
    );

    test('a second consecutive 401 is returned, not retried again', () async {
      final h = Harness();
      h.upstream.intentStatuses.addAll([401, 401]);
      final res = await h.uqpay.getPaymentIntent('pi_1');
      expect(res.statusCode, 401);
      expect(h.upstream.intentRequests, hasLength(2));
    });

    test('forwards the upstream x-trace-id', () async {
      final h = Harness();
      final res = await h.uqpay.getPaymentIntent('pi_1');
      expect(res.traceId, 'trace-abc-123');
    });
  });

  test('newIdempotencyKey is a lowercase v4 UUID', () {
    final key = newIdempotencyKey(Random(7));
    expect(
      key,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(key, equals(key.toLowerCase()));
  });
}
