import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uqpay_sdk_flutter/src/transport/failure_classifier.dart';
import 'package:uqpay_sdk_flutter/src/transport/http_package_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

void main() {
  UqpayHttpRequest request({
    String? body,
    Duration timeout = const Duration(seconds: 5),
  }) => UqpayHttpRequest(
    method: body == null ? 'GET' : 'POST',
    url: Uri.parse(
      'https://api-sandbox.uqpaytech.com/api/v2/payment_intents/x',
    ),
    headers: const {'x-auth-token': 'Bearer t', 'accept': 'application/json'},
    timeout: timeout,
    body: body,
  );

  group('HttpPackageClient', () {
    test(
      'passes method, url, headers and body through; maps the response',
      () async {
        late http.Request seen;
        final client = HttpPackageClient(
          inner: MockClient((req) async {
            seen = req;
            return http.Response(
              '{"ok":true}',
              402,
              headers: {'X-Trace-Id': 'tr', 'content-type': 'application/json'},
            );
          }),
        );

        final response = await client.send(request(body: '{"a":1}'));

        expect(seen.method, 'POST');
        expect(seen.url.host, 'api-sandbox.uqpaytech.com');
        expect(seen.headers['x-auth-token'], 'Bearer t');
        expect(seen.body, '{"a":1}');
        expect(seen.followRedirects, isFalse);
        expect(response.statusCode, 402);
        expect(response.body, '{"ok":true}');
        expect(response.traceId, 'tr');
        client
          ..close()
          ..close(); // idempotent
      },
    );

    test('a GET sends no body', () async {
      late http.Request seen;
      final client = HttpPackageClient(
        inner: MockClient((req) async {
          seen = req;
          return http.Response('', 200);
        }),
      );
      await client.send(request());
      expect(seen.method, 'GET');
      expect(seen.body, isEmpty);
    });

    test('enforces the request timeout as a typed timeout failure', () async {
      final client = HttpPackageClient(
        inner: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(
        client.send(request(timeout: const Duration(milliseconds: 20))),
        throwsA(
          isA<UqpayTransportException>()
              .having((e) => e.kind, 'kind', UqpayTransportFailureKind.timeout)
              .having((e) => e.toString(), 'toString', contains('timeout')),
        ),
      );
    });

    for (final (error, kind) in <(Object, UqpayTransportFailureKind)>[
      (
        const SocketException(
          'Failed host lookup: api-sandbox.uqpaytech.com',
          osError: OSError('nodename nor servname provided', 8),
        ),
        UqpayTransportFailureKind.dns,
      ),
      (
        const SocketException('lookup', osError: OSError('x', -2)),
        UqpayTransportFailureKind.dns,
      ),
      (
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
        ),
        UqpayTransportFailureKind.socket,
      ),
      (
        const SocketException('Connection reset'),
        UqpayTransportFailureKind.socket,
      ),
      (const HandshakeException('bad cert'), UqpayTransportFailureKind.tls),
      (const CertificateException('expired'), UqpayTransportFailureKind.tls),
      (const TlsException('generic'), UqpayTransportFailureKind.tls),
      (
        http.ClientException('Connection closed'),
        UqpayTransportFailureKind.socket,
      ),
    ]) {
      test('${error.runtimeType} → ${kind.name}', () async {
        final client = HttpPackageClient(
          inner: MockClient((_) => Future<http.Response>.error(error)),
        );
        await expectLater(
          client.send(request(body: '{"card_number":"4242424242424242"}')),
          throwsA(
            isA<UqpayTransportException>()
                .having((e) => e.kind, 'kind', kind)
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('4242424242424242')),
                ),
          ),
        );
      });
    }

    test(
      'unrelated errors are rethrown unchanged (programmer errors)',
      () async {
        final client = HttpPackageClient(
          inner: MockClient((_) => throw StateError('bug')),
        );
        await expectLater(client.send(request()), throwsStateError);
      },
    );

    test('an already-typed transport exception is rethrown as-is', () async {
      final client = HttpPackageClient(
        inner: MockClient(
          (_) => throw const UqpayTransportException(
            UqpayTransportFailureKind.tls,
            'pre-typed',
          ),
        ),
      );
      await expectLater(
        client.send(request()),
        throwsA(
          isA<UqpayTransportException>().having(
            (e) => e.message,
            'message',
            'pre-typed',
          ),
        ),
      );
    });

    test('sending after close throws StateError', () async {
      final client = HttpPackageClient(
        inner: MockClient((_) async => http.Response('', 200)),
      )..close();
      await expectLater(client.send(request()), throwsStateError);
    });

    test('constructs a real inner client when none is given', () {
      HttpPackageClient().close();
    });
  });

  group('classifyTransportError (io)', () {
    test('returns null for non-transport errors', () {
      expect(classifyTransportError(ArgumentError('x')), isNull);
      expect(classifyTransportError(const FormatException()), isNull);
    });
  });
}
