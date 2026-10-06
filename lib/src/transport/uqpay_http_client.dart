import 'package:flutter/foundation.dart';

/// An HTTP request as the SDK's transport seam sees it.
///
/// [body] is already-encoded UTF-8 text (canonical JSON). [toString] prints
/// the method and URL only — never headers (they carry the token) and never
/// the body (it may carry a card).
@immutable
class UqpayHttpRequest {
  /// Creates a request.
  const UqpayHttpRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.timeout,
    this.body,
  });

  /// `GET` or `POST`.
  final String method;

  /// Absolute `https` URL.
  final Uri url;

  /// Request headers. Names are lowercase.
  final Map<String, String> headers;

  /// Per-request timeout, enforced by the client.
  final Duration timeout;

  /// UTF-8 body, or `null` for body-less requests.
  final String? body;

  @override
  String toString() => 'UqpayHttpRequest($method $url)';
}

/// An HTTP response as the SDK's transport seam sees it.
///
/// [toString] prints the status only — never the body.
@immutable
class UqpayHttpResponse {
  /// Creates a response. Header names are lowercased on construction.
  UqpayHttpResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required this.body,
  }) : headers = Map<String, String>.unmodifiable(<String, String>{
         for (final entry in headers.entries)
           entry.key.toLowerCase(): entry.value,
       });

  /// HTTP status.
  final int statusCode;

  /// Response headers with lowercase names.
  final Map<String, String> headers;

  /// UTF-8 body (may be empty).
  final String body;

  /// The API's `x-trace-id` header, if present.
  String? get traceId => headers['x-trace-id'];

  /// The API's `x-response-id` header, if present.
  String? get responseId => headers['x-response-id'];

  /// Whether [statusCode] is 2xx.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'UqpayHttpResponse($statusCode)';
}

/// The SDK's own HTTP seam. All networking goes through an
/// implementation of this interface; tests substitute a fake and never touch
/// the network.
///
/// Implementations must throw a `UqpayTransportException` (never a raw
/// platform exception) when no HTTP response is available, and must never log
/// request or response bodies.
abstract interface class UqpayHttpClient {
  /// Sends [request] and returns the response, whatever its status.
  Future<UqpayHttpResponse> send(UqpayHttpRequest request);

  /// Releases any underlying connections. Idempotent.
  void close();
}
