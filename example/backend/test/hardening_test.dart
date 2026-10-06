// Tests for the reference backend's local-development hardening: loopback
// binding, the CORS allow-list, the forced re-mint rate limit, webhook
// payload stripping and the payment-intent field allow-list.
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:uqpay_reference_backend/uqpay_reference_backend.dart';

import 'helpers.dart';

Request req(String method, String path, {Object? json, String? origin}) =>
    Request(
      method,
      Uri.parse('http://localhost:8787$path'),
      body: json == null ? null : jsonEncode(json),
      headers: {'content-type': 'application/json', 'origin': ?origin},
    );

Future<Map<String, Object?>> body(Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, Object?>;

void main() {
  group('bind address', () {
    test('defaults to loopback', () {
      final config = BackendConfig.fromEnvironment(baseEnv());
      expect(config.bindAddress, '127.0.0.1');
      expect(config.reachableFromNetwork, isFalse);
    });

    test('UQPAY_BACKEND_BIND=0.0.0.0 is an explicit opt-in', () {
      final config = BackendConfig.fromEnvironment(
        baseEnv(extra: {'UQPAY_BACKEND_BIND': '0.0.0.0'}),
      );
      expect(config.bindAddress, '0.0.0.0');
      expect(config.reachableFromNetwork, isTrue);
    });

    test('a non-IP bind value refuses to start', () {
      expect(
        () => BackendConfig.fromEnvironment(
          baseEnv(extra: {'UQPAY_BACKEND_BIND': 'everywhere'}),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('UQPAY_BACKEND_BIND'),
          ),
        ),
      );
    });

    test('serveBackend listens on loopback by default', () async {
      final defaults = BackendConfig.fromEnvironment(baseEnv());
      final config = BackendConfig(
        environment: defaults.environment,
        clientId: defaults.clientId,
        apiKey: defaults.apiKey,
        apiBaseUrl: defaults.apiBaseUrl,
        port: 0, // any free port
      );
      final server = await serveBackend(config, (_) => Response.ok('ok'));
      addTearDown(() => server.close(force: true));
      expect(server.address.isLoopback, isTrue);
      expect(server.address.address, '127.0.0.1');
    });
  });

  group('startup banner', () {
    test('always says local development only', () {
      final lines = startupBanner(BackendConfig.fromEnvironment(baseEnv()));
      expect(
        lines.first,
        contains('local development only — never deploy this server'),
      );
      expect(lines.join('\n'), isNot(contains('WARNING')));
      expect(lines.join('\n'), isNot(contains(testApiKey)));
    });

    test('warns when reachable from the network', () {
      final lines = startupBanner(
        BackendConfig.fromEnvironment(
          baseEnv(extra: {'UQPAY_BACKEND_BIND': '0.0.0.0'}),
        ),
      );
      expect(lines.join('\n'), contains('WARNING: listening on 0.0.0.0'));
    });
  });

  group('CORS allow-list', () {
    test('reflects an allowed localhost dev origin, any port', () async {
      final h = Harness();
      for (final origin in [
        'http://localhost:5000',
        'http://localhost:61234',
        'http://127.0.0.1:8080',
      ]) {
        final res = await h.app.handler(req('GET', '/health', origin: origin));
        expect(res.statusCode, 200, reason: origin);
        expect(res.headers['access-control-allow-origin'], origin);
        expect(res.headers['vary'], contains('Origin'));
      }
    });

    test('never answers with a wildcard', () async {
      final h = Harness();
      final res = await h.app.handler(
        req('GET', '/health', origin: 'http://localhost:5000'),
      );
      expect(res.headers['access-control-allow-origin'], isNot('*'));
    });

    test('refuses other origins before any route runs', () async {
      final h = Harness();
      for (final origin in [
        'https://evil.example',
        'http://localhost.evil.example',
        'https://localhost:5000', // scheme must match too
        'null',
      ]) {
        final res = await h.app.handler(
          req('POST', '/client-token', origin: origin),
        );
        expect(res.statusCode, 403, reason: origin);
        expect(res.headers['access-control-allow-origin'], isNull);
        expect((await body(res))['code'], 'origin_not_allowed');
      }
      // A drive-by page could not even trigger a token mint.
      expect(h.upstream.tokenIssues, 0);
    });

    test('refuses a preflight from another origin', () async {
      final h = Harness();
      final res = await h.app.handler(
        req('OPTIONS', '/client-token', origin: 'https://evil.example'),
      );
      expect(res.statusCode, 403);
      expect(res.headers['access-control-allow-origin'], isNull);
    });

    test('UQPAY_BACKEND_CORS_ORIGINS replaces the default', () async {
      final h = Harness(
        extraEnv: {
          'UQPAY_BACKEND_CORS_ORIGINS':
              'https://dev.example.com:8443, http://localhost:3000',
        },
      );
      final ok = await h.app.handler(
        req('GET', '/health', origin: 'https://dev.example.com:8443'),
      );
      expect(
        ok.headers['access-control-allow-origin'],
        'https://dev.example.com:8443',
      );
      final exactPort = await h.app.handler(
        req('GET', '/health', origin: 'http://localhost:3001'),
      );
      expect(exactPort.statusCode, 403);
    });

    test('a wildcard or malformed allow-list refuses to start', () {
      for (final bad in [
        '*',
        'localhost:3000',
        'ftp://x',
        'http://x/path',
        'http://u@x',
      ]) {
        expect(
          () => BackendConfig.fromEnvironment(
            baseEnv(extra: {'UQPAY_BACKEND_CORS_ORIGINS': bad}),
          ),
          throwsA(isA<ConfigError>()),
          reason: bad,
        );
      }
    });
  });

  group('forced re-mint rate limit', () {
    Future<Response> reject(Harness h, String suffix) async => h.app.handler(
      req('POST', '/client-token', json: {'rejected_token_suffix': suffix}),
    );

    test('at most one forced mint per 30 s; otherwise the cache', () async {
      final h = Harness();
      await h.app.handler(req('POST', '/client-token'));
      expect(h.upstream.tokenIssues, 1);

      h.upstream.nextToken = 'tok_second_0002';
      await reject(h, '0001');
      expect(h.upstream.tokenIssues, 2);

      // Anyone holding the new token knows its suffix. Hammering it inside
      // the window must not kill the merchant's only token again.
      h.upstream.nextToken = 'tok_third_0003';
      for (var i = 0; i < 20; i++) {
        h.advance(const Duration(seconds: 1));
        final res = await reject(h, '0002');
        expect((await body(res))['auth_token'], 'tok_second_0002');
      }
      expect(h.upstream.tokenIssues, 2);
      expect(h.logLines.join('\n'), contains('returning the cached token'));

      // After the window a genuine report is honoured again.
      h.advance(const Duration(seconds: 11));
      final res = await reject(h, '0002');
      expect((await body(res))['auth_token'], 'tok_third_0003');
      expect(h.upstream.tokenIssues, 3);
    });

    test('the backend\'s own 401 recovery is not rate-limited', () async {
      final h = Harness();
      await h.app.handler(req('POST', '/client-token'));
      h.upstream.nextToken = 'tok_second_0002';
      await reject(h, '0001');
      expect(h.upstream.tokenIssues, 2);

      // An upstream 401 inside the window still re-issues.
      h.upstream.intentStatuses.add(401);
      final res = await h.app.handler(
        req(
          'POST',
          '/payment-intents',
          json: {'amount': '1.00', 'currency': 'USD'},
        ),
      );
      expect(res.statusCode, 200);
      expect(h.upstream.tokenIssues, 3);
    });
  });

  group('GET /webhooks/recent', () {
    test('serves only type, intent id, status and received time', () async {
      final h = Harness();
      await h.app.handler(
        req(
          'POST',
          '/webhooks/uqpay',
          json: {
            'type': 'payment_intent.succeeded',
            'data': {
              'id': 'pi_1',
              'status': 'SUCCEEDED',
              'customer': {'email': 'someone@example.com'},
              'payment_method': {
                'card': {'number': '4111111111111111'},
              },
            },
          },
        ),
      );
      final res = await h.app.handler(req('GET', '/webhooks/recent'));
      final raw = await res.readAsString();
      final events =
          (jsonDecode(raw) as Map<String, Object?>)['events']! as List<Object?>;
      final event = events.single! as Map<String, Object?>;
      expect(event.keys.toSet(), {
        'received_at',
        'event_type',
        'payment_intent_id',
        'status',
      });
      expect(event['payment_intent_id'], 'pi_1');
      expect(raw, isNot(contains('4111')));
      expect(raw, isNot(contains('someone@example.com')));
      expect(raw, isNot(contains('payload')));
    });

    test('values are length-capped and cannot forge log lines', () async {
      final h = Harness();
      await h.app.handler(
        req(
          'POST',
          '/webhooks/uqpay',
          json: {
            'type': 'x\nwebhook: type=forged intent=pi_evil status=SUCCEEDED',
            'payment_intent_id': 'p' * 10000,
            'status': 'OK',
          },
        ),
      );
      expect(h.logLines.where((l) => l.contains('\n')), isEmpty);
      final event = h.app.webhooks.recent.single;
      expect(event.eventType, isNot(contains('\n')));
      expect(event.paymentIntentId!.length, WebhookEvent.maxFieldLength);
    });
  });

  group('POST /payment-intents field allow-list', () {
    test('refuses any field outside the allow-list', () async {
      for (final extra in <String, Object?>{
        'capture_method': 'manual',
        'customer_id': 'cus_1',
        'payment_method_options': {'card': <String, Object?>{}},
        'amount_minor': 1,
      }.entries) {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {'amount': '1.00', 'currency': 'USD', extra.key: extra.value},
          ),
        );
        expect(res.statusCode, 400, reason: extra.key);
        expect((await body(res))['code'], 'unknown_field');
        expect(h.upstream.intentRequests, isEmpty);
      }
    });

    test('forwards exactly the allowed fields', () async {
      final h = Harness();
      final res = await h.app.handler(
        req(
          'POST',
          '/payment-intents',
          json: {
            'amount': '1.00',
            'currency': 'USD',
            'return_url': 'uqpayexample://payment',
            'description': 'Order 1',
            'merchant_order_id': 'order-1',
            'metadata': {'k': 'v'},
          },
        ),
      );
      expect(res.statusCode, 200);
      final sent =
          jsonDecode(h.upstream.intentRequests.single.body)
              as Map<String, Object?>;
      expect(sent.keys.toSet(), {
        'amount',
        'currency',
        'return_url',
        'description',
        'merchant_order_id',
        'metadata',
      });
    });

    test('allowed fields still need the right type', () async {
      for (final bad in <String, Object?>{
        'return_url': 42,
        'merchant_order_id': '',
        'metadata': 'not an object',
      }.entries) {
        final h = Harness();
        final res = await h.app.handler(
          req(
            'POST',
            '/payment-intents',
            json: {'amount': '1.00', 'currency': 'USD', bad.key: bad.value},
          ),
        );
        expect(res.statusCode, 400, reason: bad.key);
        expect(h.upstream.intentRequests, isEmpty);
      }
    });
  });
}
