/// The distinct ways a request can fail before an HTTP status is available.
/// Internal — surfaced to merchants only through the mapped
/// `UqpayErrorCode`.
enum UqpayTransportFailureKind {
  /// Host name resolution failed. The request never left the device.
  dns,

  /// Socket-level failure: refused, reset, unreachable, offline. The request
  /// may or may not have reached the server.
  socket,

  /// The request exceeded its timeout. The request may have reached the
  /// server.
  timeout,

  /// The TLS handshake failed. The request never left the device.
  tls,
}

/// Thrown by a `UqpayHttpClient` implementation when the request fails
/// without an HTTP response. Internal; the API client converts it into a
/// returned `UqpayError`.
class UqpayTransportException implements Exception {
  /// Creates a transport exception. [message] must never contain a request
  /// body.
  const UqpayTransportException(this.kind, this.message);

  /// What kind of failure occurred.
  final UqpayTransportFailureKind kind;

  /// A short developer-facing description (no body content).
  final String message;

  @override
  String toString() => 'UqpayTransportException(${kind.name}: $message)';
}
