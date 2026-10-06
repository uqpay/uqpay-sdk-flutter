/// Authenticated calls to the UQPAY payment-intent endpoints, made with the
/// server-owned token from [TokenManager].
library;

import 'dart:math';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'token_manager.dart';

/// Result of an upstream call, passed back to the app verbatim.
class UpstreamResponse {
  UpstreamResponse({
    required this.statusCode,
    required this.body,
    this.traceId,
  });

  final int statusCode;

  /// Raw JSON body from UQPAY, untouched.
  final String body;

  /// Upstream `x-trace-id`, forwarded so support can correlate requests.
  final String? traceId;
}

class UqpayClient {
  UqpayClient({
    required BackendConfig config,
    required TokenManager tokens,
    required http.Client client,
    Random? random,
  }) : _config = config,
       _tokens = tokens,
       _client = client,
       _random = random ?? Random.secure();

  final BackendConfig _config;
  final TokenManager _tokens;
  final http.Client _client;
  final Random _random;

  /// `POST /api/v2/payment_intents/create`. [body] is the
  /// already-encoded JSON; this class does not touch the amount.
  Future<UpstreamResponse> createPaymentIntent(String body) => _send(
    'POST',
    '/api/v2/payment_intents/create',
    body: body,
    idempotencyKey: newIdempotencyKey(_random),
  );

  /// `GET /api/v2/payment_intents/{id}`.
  Future<UpstreamResponse> getPaymentIntent(String id) =>
      _send('GET', '/api/v2/payment_intents/${Uri.encodeComponent(id)}');

  /// Sends once; on 401 invalidates the token and retries exactly once with
  /// the SAME idempotency key.
  Future<UpstreamResponse> _send(
    String method,
    String path, {
    String? body,
    String? idempotencyKey,
  }) async {
    var response = await _once(method, path, body, idempotencyKey);
    if (response.statusCode == 401) {
      _tokens.invalidate();
      response = await _once(method, path, body, idempotencyKey);
    }
    return UpstreamResponse(
      statusCode: response.statusCode,
      body: response.body,
      traceId: response.headers['x-trace-id'],
    );
  }

  Future<http.Response> _once(
    String method,
    String path,
    String? body,
    String? idempotencyKey,
  ) async {
    final token = await _tokens.getToken();
    final uri = _config.apiBaseUrl.resolve(path);
    // The header set UQPAY's payment-intent API expects.
    final headers = <String, String>{
      'x-auth-token': 'Bearer ${token.value}',
      'x-client-id': _config.clientId,
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      'x-idempotency-key': ?idempotencyKey,
      'x-on-behalf-of': ?_config.onBehalfOf,
    };
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = body;
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }
}

/// Lowercase RFC 4122 v4 UUID. The server rejects uppercase keys.
String newIdempotencyKey(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
