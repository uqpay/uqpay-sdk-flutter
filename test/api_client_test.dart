import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_api_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

import 'support/fakes.dart';

void main() {
  late FakeHttpClient http;
  late FakeClock clock;

  setUp(() {
    http = FakeHttpClient();
    clock = FakeClock();
  });

  UqpayApiClient client(UqpaySdk sdk) =>
      UqpayApiClient(sdk: sdk, httpClient: http, clock: clock);

  UqpayError failureOf(UqpayApiResult<UqpayPaymentIntent> result) =>
      (result as UqpayApiFailure<UqpayPaymentIntent>).error;

  UqpayPaymentIntent successOf(UqpayApiResult<UqpayPaymentIntent> result) =>
      (result as UqpayApiSuccess<UqpayPaymentIntent>).value;

  group('configuration', () {
    test('a missing tokenProvider throws ArgumentError naming it', () {
      expect(
        () => client(UqpaySdk.init(environment: UqpayEnvironment.sandbox)),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'tokenProvider'),
        ),
      );
      expect(http.requests, isEmpty);
    });

    test('an empty intent id or idempotency key throws before sending', () {
      final api = client(sdkWithTokens(['tok']));
      expect(
        () => api.retrievePaymentIntent(' '),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'paymentIntentId'),
        ),
      );
      expect(
        () => api.confirmPaymentIntent(
          id: 'pi_1',
          request: cardConfirmRequest(),
          idempotencyKey: '',
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'idempotencyKey'),
        ),
      );
      expect(http.requests, isEmpty);
    });
  });

  group('headers', () {
    test('GET sends x-auth-token Bearer, accept, no body headers', () async {
      http.enqueue(jsonResponse(200, intentJson()));
      final api = client(sdkWithTokens(['tok-1']));

      final result = await api.retrievePaymentIntent('pi_123');

      expect(successOf(result).id, 'pi_123');
      final request = http.requests.single;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://api-sandbox.uqpaytech.com/api/v2/payment_intents/pi_123',
      );
      expect(request.headers['x-auth-token'], 'Bearer tok-1');
      expect(request.headers['accept'], 'application/json');
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('content-type'), isFalse);
      expect(request.headers.containsKey('x-idempotency-key'), isFalse);
      expect(request.headers.containsKey('x-client-id'), isFalse);
      expect(request.headers.containsKey('x-on-behalf-of'), isFalse);
      expect(request.body, isNull);
      expect(request.timeout, const Duration(seconds: 30));
    });

    test(
      'POST confirm sends idempotency key, content-type, canonical body',
      () async {
        http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
        final api = client(
          sdkWithTokens(
            ['tok-1'],
            environment: UqpayEnvironment.production,
            clientId: 'client-1',
            onBehalfOf: 'acct_sub',
          ),
        );
        final body = cardConfirmRequest();

        final result = await api.confirmPaymentIntent(
          id: 'pi 1/x',
          request: body,
          idempotencyKey: 'abc-key',
        );

        expect(successOf(result).status, UqpayIntentStatus.succeeded);
        final request = http.requests.single;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api.uqpay.com/api/v2/payment_intents/pi%201%2Fx/confirm',
        );
        expect(request.headers['x-auth-token'], 'Bearer tok-1');
        expect(request.headers['content-type'], 'application/json');
        expect(request.headers['x-idempotency-key'], 'abc-key');
        expect(request.headers['x-client-id'], 'client-1');
        expect(request.headers['x-on-behalf-of'], 'acct_sub');
        expect(request.body, body.toCanonicalJson());
        // Sorted keys → byte-stable across re-encodes.
        final decoded = jsonDecode(request.body!) as Map<String, Object?>;
        expect(decoded.keys.toList(), [
          'browser_info',
          'ip_address',
          'payment_method',
        ]);
      },
    );

    test(
      'a retry with the same key and request produces identical bytes',
      () async {
        http
          ..enqueue(jsonResponse(500, {'code': 'system_error'}))
          ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
        final api = client(sdkWithTokens(['tok-1']));

        final first = await api.confirmPaymentIntent(
          id: 'pi_1',
          request: cardConfirmRequest(),
          idempotencyKey: 'k',
        );
        expect(failureOf(first).isOutcomeUnknown, isTrue);
        final second = await api.confirmPaymentIntent(
          id: 'pi_1',
          request: cardConfirmRequest(),
          idempotencyKey: 'k',
        );
        expect(second, isA<UqpayApiSuccess<UqpayPaymentIntent>>());
        expect(http.requests[0].body, http.requests[1].body);
        expect(
          http.requests[0].headers['x-idempotency-key'],
          http.requests[1].headers['x-idempotency-key'],
        );
      },
    );
  });

  group('token lifecycle', () {
    test('caches the token across requests', () async {
      final calls = <int>[];
      http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson()));
      final api = client(sdkWithTokens(['tok-1'], providerCalls: calls));

      await api.retrievePaymentIntent('pi_1');
      await api.retrievePaymentIntent('pi_1');

      expect(calls, hasLength(1));
      expect(http.requests.map((r) => r.headers['x-auth-token']), [
        'Bearer tok-1',
        'Bearer tok-1',
      ]);
    });

    test('on 401 refreshes the token and retries exactly once', () async {
      final calls = <int>[];
      http
        ..enqueue(
          jsonResponse(401, {
            'code': 'unauthorized',
            'type': 'unauthorized_error',
          }),
        )
        ..enqueue(jsonResponse(200, intentJson()));
      final api = client(
        sdkWithTokens(['tok-1', 'tok-2'], providerCalls: calls),
      );

      final result = await api.confirmPaymentIntent(
        id: 'pi_1',
        request: cardConfirmRequest(),
        idempotencyKey: 'k',
      );

      expect(result, isA<UqpayApiSuccess<UqpayPaymentIntent>>());
      expect(calls, hasLength(2));
      expect(http.requests, hasLength(2));
      expect(http.requests[0].headers['x-auth-token'], 'Bearer tok-1');
      expect(http.requests[1].headers['x-auth-token'], 'Bearer tok-2');
      expect(http.requests[0].body, http.requests[1].body);
      expect(http.requests[1].headers['x-idempotency-key'], 'k');
    });

    test(
      'a second 401 is returned as authenticationFailed, no third try',
      () async {
        http
          ..enqueue(jsonResponse(401, {'code': 'unauthorized'}, traceId: 't-a'))
          ..enqueue(
            jsonResponse(401, {'code': 'unauthorized'}, traceId: 't-b'),
          );
        final api = client(sdkWithTokens(['tok-1', 'tok-2', 'tok-3']));

        final error = failureOf(await api.retrievePaymentIntent('pi_1'));

        expect(error.code, UqpayErrorCode.authenticationFailed);
        expect(error.httpStatus, 401);
        expect(error.traceId, 't-b');
        expect(error.serverCode, 'unauthorized');
        expect(error.isRetryable, isFalse);
        expect(http.requests, hasLength(2));
      },
    );

    test('a throwing tokenProvider is returned, not thrown', () async {
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        tokenProvider: () async => throw Exception('backend down'),
      );
      final error = failureOf(await client(sdk).retrievePaymentIntent('pi_1'));
      expect(error.code, UqpayErrorCode.authenticationFailed);
      expect(error.developerMessage, contains('tokenProvider'));
      expect(error.developerMessage, isNot(contains('backend down')));
      expect(http.requests, isEmpty);
    });

    test('a tokenProvider that throws an Error is also contained', () async {
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        tokenProvider: () async => throw StateError('bug'),
      );
      final error = failureOf(await client(sdk).retrievePaymentIntent('pi_1'));
      expect(error.code, UqpayErrorCode.authenticationFailed);
      expect(error.developerMessage, contains('error'));
    });
  });

  group('response handling', () {
    test('a 4xx envelope maps and carries trace ids', () async {
      http.enqueue(
        jsonResponse(
          402,
          {
            'code': 'insufficient_funds',
            'type': 'card_error',
            'message': 'nope',
          },
          traceId: 'trace-42',
          responseId: 'resp-42',
        ),
      );
      final error = failureOf(
        await client(sdkWithTokens(['t'])).confirmPaymentIntent(
          id: 'pi_1',
          request: cardConfirmRequest(),
          idempotencyKey: 'k',
        ),
      );
      expect(error.code, UqpayErrorCode.insufficientFunds);
      expect(error.httpStatus, 402);
      expect(error.traceId, 'trace-42');
      expect(error.responseId, 'resp-42');
      expect(error.serverCode, 'insufficient_funds');
      expect(error.serverMessage, 'nope');
      expect(error.isRetryable, isFalse);
    });

    test(
      'an all-empty envelope falls back to status; empty body too',
      () async {
        http
          ..enqueue(jsonResponse(400, {'code': '', 'type': '', 'message': ''}))
          ..enqueue(jsonResponse(404, ''))
          ..enqueue(jsonResponse(400, <Object?>[1, 2]));
        final api = client(sdkWithTokens(['t']));

        final a = failureOf(await api.retrievePaymentIntent('pi_1'));
        expect(a.code, UqpayErrorCode.invalidPaymentMethod);
        expect(a.serverCode, isNull);
        expect(a.serverMessage, isNull);

        final b = failureOf(await api.retrievePaymentIntent('pi_1'));
        expect(b.code, UqpayErrorCode.invalidPaymentMethod);
        expect(b.httpStatus, 404);
        expect(b.serverMessage, isNull);

        final c = failureOf(await api.retrievePaymentIntent('pi_1'));
        expect(c.code, UqpayErrorCode.invalidPaymentMethod);
        expect(c.serverMessage, '[1,2]');
      },
    );

    test('a non-JSON error body is bounded, one line, digits masked', () async {
      final html =
          '<html>\n\n<body>  Bad gateway 4242424242424242 '
          '${'x' * 400}</body></html>';
      http.enqueue(jsonResponse(502, html, traceId: null, responseId: null));
      final error = failureOf(
        await client(sdkWithTokens(['t'])).retrievePaymentIntent('pi_1'),
      );
      expect(error.code, UqpayErrorCode.serverError);
      expect(error.serverMessage, isNotNull);
      expect(error.serverMessage, isNot(contains('\n')));
      expect(error.serverMessage!.length, lessThanOrEqualTo(301));
      expect(error.serverMessage, endsWith('…'));
      expect(error.serverMessage, isNot(contains('4242424242424242')));
      expect(error.serverMessage, contains('[digits]'));
      expect(error.traceId, isNull);
      expect(error.responseId, isNull);
      expect(error.isOutcomeUnknown, isTrue);
    });

    test('a whitespace-only error body yields no server message', () async {
      http.enqueue(jsonResponse(500, '  \n '));
      final error = failureOf(
        await client(sdkWithTokens(['t'])).retrievePaymentIntent('pi_1'),
      );
      expect(error.serverMessage, isNull);
    });

    test(
      'a 2xx that is not JSON maps to malformedResponse, outcome unknown',
      () async {
        http.enqueue(jsonResponse(200, '<html>oops</html>', traceId: 'tr'));
        final error = failureOf(
          await client(sdkWithTokens(['t'])).confirmPaymentIntent(
            id: 'pi_1',
            request: cardConfirmRequest(),
            idempotencyKey: 'k',
          ),
        );
        expect(error.code, UqpayErrorCode.malformedResponse);
        expect(error.isOutcomeUnknown, isTrue);
        expect(error.isRetryable, isFalse);
        expect(error.httpStatus, 200);
        expect(error.traceId, 'tr');
      },
    );

    test('a 2xx JSON array or an intent without id is malformed too', () async {
      http
        ..enqueue(jsonResponse(200, <Object?>[]))
        ..enqueue(jsonResponse(201, {'intent_status': 'SUCCEEDED'}));
      final api = client(sdkWithTokens(['t']));
      expect(
        failureOf(await api.retrievePaymentIntent('pi_1')).code,
        UqpayErrorCode.malformedResponse,
      );
      final second = failureOf(await api.retrievePaymentIntent('pi_1'));
      expect(second.code, UqpayErrorCode.malformedResponse);
      expect(second.httpStatus, 201);
    });

    test('a 2xx with an unknown status decodes without failing', () async {
      http.enqueue(jsonResponse(200, intentJson(status: 'NEW_STATUS')));
      final intent = successOf(
        await client(sdkWithTokens(['t'])).retrievePaymentIntent('pi_1'),
      );
      expect(intent.status.isUnknown, isTrue);
      expect(intent.status.isSuccess, isFalse);
    });

    test('success carries the trace ids', () async {
      http.enqueue(
        jsonResponse(200, intentJson(), traceId: 'T', responseId: 'R'),
      );
      final result =
          await client(sdkWithTokens(['t'])).retrievePaymentIntent('pi_1')
              as UqpayApiSuccess<UqpayPaymentIntent>;
      expect(result.traceId, 'T');
      expect(result.responseId, 'R');
    });

    for (final (kind, code) in <(UqpayTransportFailureKind, UqpayErrorCode)>[
      (UqpayTransportFailureKind.dns, UqpayErrorCode.dnsFailure),
      (UqpayTransportFailureKind.socket, UqpayErrorCode.networkError),
      (UqpayTransportFailureKind.timeout, UqpayErrorCode.timeout),
      (UqpayTransportFailureKind.tls, UqpayErrorCode.tlsFailure),
    ]) {
      test(
        'transport failure ${kind.name} → ${code.raw}, returned not thrown',
        () async {
          http.enqueueError(UqpayTransportException(kind, 'boom'));
          final error = failureOf(
            await client(sdkWithTokens(['t'])).retrievePaymentIntent('pi_1'),
          );
          expect(error.code, code);
          expect(error.httpStatus, isNull);
          expect(error.traceId, isNull);
        },
      );
    }

    test('a transport failure on the 401 retry is also returned', () async {
      http
        ..enqueue(jsonResponse(401, {}))
        ..enqueueError(
          const UqpayTransportException(UqpayTransportFailureKind.timeout, 'x'),
        );
      final error = failureOf(
        await client(sdkWithTokens(['a', 'b'])).retrievePaymentIntent('pi_1'),
      );
      expect(error.code, UqpayErrorCode.timeout);
      expect(http.requests, hasLength(2));
    });
  });

  group('UqpayHttpResponse / UqpayHttpRequest', () {
    test('lowercases header names and exposes trace ids', () {
      final response = UqpayHttpResponse(
        statusCode: 204,
        headers: const {'X-Trace-Id': 'a', 'X-RESPONSE-ID': 'b'},
        body: '',
      );
      expect(response.headers, {'x-trace-id': 'a', 'x-response-id': 'b'});
      expect(response.traceId, 'a');
      expect(response.responseId, 'b');
      expect(response.isSuccess, isTrue);
      expect(response.toString(), 'UqpayHttpResponse(204)');
      expect(() => response.headers['x'] = 'y', throwsUnsupportedError);
    });

    test('request toString never includes headers or body', () {
      final request = UqpayHttpRequest(
        method: 'POST',
        url: Uri.parse('https://api.uqpay.com/x'),
        headers: const {'x-auth-token': 'Bearer secret'},
        timeout: const Duration(seconds: 1),
        body: '{"card_number":"$testPan"}',
      );
      expect(
        request.toString(),
        'UqpayHttpRequest(POST https://api.uqpay.com/x)',
      );
    });
  });
}
