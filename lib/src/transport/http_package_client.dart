import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uqpay_sdk_flutter/src/transport/default_inner_client_stub.dart'
    if (dart.library.io) 'package:uqpay_sdk_flutter/src/transport/default_inner_client_io.dart';
import 'package:uqpay_sdk_flutter/src/transport/failure_classifier.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

/// The production [UqpayHttpClient], backed by `package:http`.
///
/// * Uses the platform's default TLS validation and never overrides
///   `badCertificateCallback` — there is no hook to do so.
/// * Enforces the per-request timeout itself so behaviour is identical on
///   every platform.
/// * Converts every low-level failure into a typed [UqpayTransportException]
///   (DNS / socket / timeout / TLS) so the mapper can keep them distinct.
/// * Logs nothing. Bodies never appear in any exception message.
class HttpPackageClient implements UqpayHttpClient {
  /// Creates a client. [inner] is injectable for tests; production callers
  /// leave it unset and get a fresh `http.Client`.
  HttpPackageClient({http.Client? inner})
    : _inner = inner ?? createDefaultInnerClient();

  final http.Client _inner;
  bool _closed = false;

  @override
  Future<UqpayHttpResponse> send(UqpayHttpRequest request) async {
    if (_closed) {
      throw StateError('HttpPackageClient has been closed');
    }
    final wire = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..followRedirects = false;
    if (request.body != null) {
      wire.body = request.body!;
    }

    try {
      final streamed = await _inner.send(wire).timeout(request.timeout);
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(request.timeout);
      // The API is UTF-8 JSON. Decoding by the declared charset would turn a
      // `text/plain` or charset-less body into latin1 mojibake; decoding
      // leniently as UTF-8 keeps invalid bytes from throwing.
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      return UqpayHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: body,
      );
    } on TimeoutException {
      throw UqpayTransportException(
        UqpayTransportFailureKind.timeout,
        'no response within ${request.timeout.inSeconds}s',
      );
    } on UqpayTransportException {
      rethrow;
    } on FormatException {
      // A malformed header value or URL: the request never left. Reported
      // with a fixed message — the platform's own text can echo the header.
      throw const UqpayTransportException(
        UqpayTransportFailureKind.socket,
        'the request could not be built (invalid header or URL)',
      );
    } catch (error) {
      final kind = classifyTransportError(error);
      if (kind == null) {
        rethrow;
      }
      // Deliberately not `error.toString()`: platform messages can include
      // the URL and, on some stacks, request details.
      throw UqpayTransportException(kind, 'transport failure (${kind.name})');
    }
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _inner.close();
    }
  }
}
