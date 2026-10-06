import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Request req(String method, String path, {Object? json, String? raw}) => Request(
  method,
  Uri.parse('http://localhost:8787$path'),
  body: raw ?? (json == null ? null : jsonEncode(json)),
  headers: {'content-type': 'application/json'},
);

Future<Map<String, Object?>> body(Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, Object?>;

void main() {
  group('BackendApp', () {
    test('GET /health', () async {
      final h = Harness();
      final res = await h.app.handler(req('GET', '/health'));
      expect(res.statusCode, 200);
      expect(await body(res), {'ok': true, 'environment': 'sandbox'});
      // No Origin header (the mobile app): served, and no wildcard CORS.
      expect(res.headers['access-control-allow-origin'], isNull);
    });

    test('OPTIONS preflight is answered for an allowed origin', () async {
      final h = Harness();
      final res = await h.app.handler(
        Request(
          'OPTIONS',
          Uri.parse('http://localhost:8787/payment-intents'),
          headers: {'origin': 'http://localhost:61234'},
        ),
      );
      expect(res.statusCode, 204);
      expect(
        res.headers['access-control-allow-origin'],
        'http://localhost:61234',
      );
      expect(res.headers['access-control-allow-methods'], contains('POST'));
    });

    test('POST /client-token hands out the cached token with expiry', () async {
      final h = Harness();
      h.upstream.expiredAt = h.now.millisecondsSinceEpoch ~/ 1000 + 1800;
      final res = await h.app.handler(req('POST', '/client-token'));
      expect(res.statusCode, 200);
      final json = await body(res);
      expect(json['token'], 'tok_first_0001');
      expect(json['auth_token'], 'tok_first_0001');
      expect(json['expires_at'], '2026-08-18T12:30:00.000Z');
      expect(json['expired_at'], h.now.millisecondsSinceEpoch ~/ 1000 + 1800);

      // The client id rides along so the app can send `x-client-id`. It is
      // not a secret (the API key is), and sending it removes the risk of a
      // confirm failing as a misleading `authentication_failed`.
      expect(json['client_id'], isNotNull);
      expect(json['client_id'], isNot(contains('key')));

      // Second call reuses the token: still exactly one upstream issue.
      await h.app.handler(req('POST', '/client-token'));
      expect(h.upstream.tokenIssues, 1);
    });

    group('POST /client-token with rejected_token_suffix', () {
      test('matching suffix forces exactly one fresh mint', () async {
        final h = Harness();
        await h.app.handler(req('POST', '/client-token'));
        expect(h.upstream.tokenIssues, 1);

        h.upstream.nextToken = 'tok_second_0002';
        final res = await h.app.handler(
          req('POST', '/client-token', json: {'rejected_token_suffix': '0001'}),
        );
        expect(res.statusCode, 200);
        expect((await body(res))['auth_token'], 'tok_second_0002');
        expect(h.upstream.tokenIssues, 2);

        // The log names the suffix only — the same mask the issue line uses.
        expect(h.logLines.join('\n'), contains('****0001 reported rejected'));
        expect(h.logLines.join('\n'), isNot(contains('tok_first_0001')));

        // Reporting the now-dead token again is a no-op: the cache has moved
        // on, so no further upstream call.
        await h.app.handler(
          req('POST', '/client-token', json: {'rejected_token_suffix': '0001'}),
        );
        expect(h.upstream.tokenIssues, 2);
      });

      test(
        'mismatching suffix returns the cached token, no upstream call',
        () async {
          final h = Harness();
          await h.app.handler(req('POST', '/client-token'));
          h.upstream.nextToken = 'tok_never_9999';

          final res = await h.app.handler(
            req(
              'POST',
              '/client-token',
              json: {'rejected_token_suffix': 'zzzz'},
            ),
          );
          expect(res.statusCode, 200);
          expect((await body(res))['auth_token'], 'tok_first_0001');
          expect(h.upstream.tokenIssues, 1);
        },
      );

      test('an empty suffix cannot force a mint', () async {
        final h = Harness();
        await h.app.handler(req('POST', '/client-token'));
        final res = await h.app.handler(
          req('POST', '/client-token', json: {'rejected_token_suffix': ''}),
        );
        expect(res.statusCode, 400);
        expect((await body(res))['code'], 'invalid_rejected_token_suffix');
        expect(h.upstream.tokenIssues, 1);
      });

      test('concurrent forced refreshes share one upstream call', () async {
        final h = Harness();
        await h.app.handler(req('POST', '/client-token'));
        expect(h.upstream.tokenIssues, 1);

        h.upstream.nextToken = 'tok_second_0002';
        h.upstream.tokenGate = Completer<void>();
        final futures = List.generate(
          10,
          (_) async => h.app.handler(
            req(
              'POST',
              '/client-token',
              json: {'rejected_token_suffix': '0001'},
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(h.upstream.tokenIssues, 2, reason: 'one in-flight mint');

        h.upstream.tokenGate!.complete();
        final responses = await Future.wait<Response>(futures);
        final issued = <String>{};
        for (final r in responses) {
          expect(r.statusCode, 200);
          issued.add((await body(r))['auth_token']! as String);
        }
        expect(issued, {'tok_second_0002'});
        expect(h.upstream.tokenIssues, 2);
      });

      test('a non-JSON body is a 400', () async {
        final h = Harness();
        final res = await h.app.handler(
          req('POST', '/client-token', raw: 'not json'),
        );
        expect(res.statusCode, 400);
        expect((await body(res))['code'], 'invalid_json');
      });
    });

    test('POST /client-token never leaks the API key', () async {
      final h = Harness();
      final res = await h.app.handler(req('POST', '/client-token'));
      final raw = await res.readAsString();
      expect(raw, isNot(contains(h.config.apiKey)));
    });

    test(
      'POST /payment-intents forwards amount byte-exact, adds order id',
      () async {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {
              'amount': '10.50',
              'currency': 'USD',
              'return_url': 'uqpayexample://payment',
              'description': 'Test order',
              'metadata': {'order': 'A-1'},
            },
          ),
        );
        expect(res.statusCode, 200);
        expect(res.headers['x-trace-id'], 'trace-abc-123');

        final upstreamBody = h.upstream.intentRequests.single.body;
        // Byte-exact: the string "10.50" survives — not 10.5, not 1050.
        expect(upstreamBody, contains('"amount":"10.50"'));
        final sent = jsonDecode(upstreamBody) as Map<String, Object?>;
        expect(sent['amount'], '10.50');
        expect(sent['currency'], 'USD');
        expect(sent['return_url'], 'uqpayexample://payment');
        expect(sent['description'], 'Test order');
        expect(sent['metadata'], {'order': 'A-1'});
        expect(sent['merchant_order_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));

        // Response is the upstream body verbatim.
        final json = await body(res);
        expect(json['id'], 'pi_test_0001');
      },
    );

    test(
      'POST /payment-intents keeps a caller-supplied merchant_order_id',
      () async {
        final h = Harness();
        await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {
              'amount': '8.98',
              'currency': 'SGD',
              'merchant_order_id': 'order-42',
            },
          ),
        );
        final sent =
            jsonDecode(h.upstream.intentRequests.single.body)
                as Map<String, Object?>;
        expect(sent['merchant_order_id'], 'order-42');
        expect(sent['amount'], '8.98');
      },
    );

    test(
      'POST /payment-intents rejects a numeric amount (never scales)',
      () async {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            raw: '{"amount": 8.98, "currency": "USD"}',
          ),
        );
        expect(res.statusCode, 400);
        expect((await body(res))['code'], 'invalid_amount');
        expect(h.upstream.intentRequests, isEmpty);
      },
    );

    test(
      'POST /payment-intents mints a description when none is supplied',
      () async {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {
              'amount': '8.98',
              'currency': 'SGD',
              'merchant_order_id': 'order-42',
            },
          ),
        );
        expect(res.statusCode, 200);
        final sent =
            jsonDecode(h.upstream.intentRequests.single.body)
                as Map<String, Object?>;
        // The gateway requires description and caps it at 32 characters; a
        // request without one must still reach it complete and in range.
        expect(sent['description'], 'Order order-42');
        expect((sent['description']! as String).length, lessThanOrEqualTo(32));
      },
    );

    test('POST /payment-intents rejects a description the gateway would '
        'reject, without calling it', () async {
      for (final bad in <Object?>['', '   ', 'x' * 33, 42]) {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {'amount': '1.00', 'currency': 'SGD', 'description': bad},
          ),
        );
        expect(res.statusCode, 400, reason: 'description: $bad');
        expect((await body(res))['code'], 'invalid_description');
        expect(h.upstream.intentRequests, isEmpty);
      }
    });

    test(
      'POST /payment-intents accepts a description at the 32-char limit',
      () async {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {
              'amount': '1.00',
              'currency': 'SGD',
              'description': 'x' * 32,
            },
          ),
        );
        expect(res.statusCode, 200);
      },
    );

    test(
      'POST /payment-intents rejects malformed JSON and bad currency',
      () async {
        final h = Harness();
        final bad = await h.app.handler(
          req('POST', '/payment-intents', raw: '{not json'),
        );
        expect(bad.statusCode, 400);
        final cur = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {'amount': '1.00', 'currency': 'dollars'},
          ),
        );
        expect(cur.statusCode, 400);
        expect((await body(cur))['code'], 'invalid_currency');
      },
    );

    test(
      'POST /payment-intents passes upstream error status through',
      () async {
        final h = Harness();
        h.upstream.intentStatuses.add(400);
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {'amount': '1.00', 'currency': 'USD'},
          ),
        );
        expect(res.statusCode, 400);
        expect(res.headers['x-trace-id'], 'trace-abc-123');
      },
    );

    test('POST /payment-intents recovers from an upstream 401', () async {
      final h = Harness();
      h.upstream.intentStatuses.add(401);
      final res = await h.app.handler(
        req(
          'POST',
          '/payment-intents',
          json: {'amount': '1.00', 'currency': 'USD'},
        ),
      );
      expect(res.statusCode, 200);
      expect(h.upstream.tokenIssues, 2);
    });

    test('GET /payment-intents/{id} proxies and forwards trace id', () async {
      final h = Harness();
      final res = await h.app.handler(req('GET', '/payment-intents/pi_9'));
      expect(res.statusCode, 200);
      expect(res.headers['x-trace-id'], 'trace-abc-123');
      expect(
        h.upstream.intentRequests.single.url.path,
        '/api/v2/payment_intents/pi_9',
      );
    });

    test(
      'webhooks are stored newest-first and summarised in the log',
      () async {
        final h = Harness();
        final first = await h.app.handler(
          req(
            'POST',
            '/webhooks/uqpay',
            json: {
              'type': 'payment_intent.succeeded',
              'data': {
                'id': 'pi_1',
                'status': 'SUCCEEDED',
                'payment_method': {
                  'card': {'number': '4111111111111111'},
                },
              },
            },
          ),
        );
        expect(first.statusCode, 200);
        h.advance(const Duration(seconds: 5));
        await h.app.handler(
          req(
            'POST',
            '/webhooks/uqpay',
            json: {
              'event_type': 'payment_intent.failed',
              'payment_intent_id': 'pi_2',
              'status': 'FAILED',
            },
          ),
        );

        final res = await h.app.handler(req('GET', '/webhooks/recent'));
        final events = (await body(res))['events'] as List<Object?>;
        expect(events, hasLength(2));
        final newest = events.first as Map<String, Object?>;
        expect(newest['payment_intent_id'], 'pi_2');
        expect(newest['event_type'], 'payment_intent.failed');
        expect(newest['status'], 'FAILED');
        final oldest = events.last as Map<String, Object?>;
        expect(oldest['payment_intent_id'], 'pi_1');
        expect(oldest['status'], 'SUCCEEDED');

        final webhookLogs = h.logLines
            .where((l) => l.startsWith('webhook:'))
            .toList();
        expect(webhookLogs, hasLength(2));
        expect(
          webhookLogs.first,
          'webhook: type=payment_intent.succeeded intent=pi_1 status=SUCCEEDED',
        );
        expect(h.logLines.join('\n'), isNot(contains('4111')));
      },
    );

    test(
      'token issue failure surfaces as 502 without leaking credentials',
      () async {
        final h = Harness();
        h.upstream.tokenStatus = 401;
        final res = await h.app.handler(req('POST', '/client-token'));
        expect(res.statusCode, 502);
        final json = await body(res);
        expect(json['code'], 'token_issue_failed');
        expect(json['message'], contains('api key rejected'));
        expect(h.logLines.join('\n'), isNot(contains(testApiKey)));

        // Next attempt tries again (no poisoned cache).
        h.upstream.tokenStatus = null;
        final ok = await h.app.handler(req('POST', '/client-token'));
        expect(ok.statusCode, 200);
      },
    );

    test('unknown routes return a JSON 404', () async {
      final h = Harness();
      final res = await h.app.handler(req('GET', '/nope'));
      expect(res.statusCode, 404);
      expect((await body(res))['code'], 'not_found');
    });
  });
}
