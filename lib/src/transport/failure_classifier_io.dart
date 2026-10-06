import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

/// Classifies a low-level error on `dart:io` platforms (Android, iOS).
///
/// Distinguishes DNS (host lookup) failures, TLS handshake / certificate
/// failures and generic socket failures. Returns `null` for errors
/// that are not transport failures.
UqpayTransportFailureKind? classifyTransportError(Object error) {
  // HandshakeException and CertificateException both implement TlsException.
  if (error is TlsException) {
    return UqpayTransportFailureKind.tls;
  }
  if (error is SocketException) {
    final os = error.osError;
    final text = '${error.message} ${os?.message ?? ''}'.toLowerCase();
    // errno 8 (macOS EAI_NONAME), 7 (iOS), -2 (glibc EAI_NONAME),
    // 11001 (Windows WSAHOST_NOT_FOUND) — plus the message Dart itself
    // uses for a failed lookup.
    const dnsErrnos = <int>{7, 8, -2, -3, 11001};
    if (text.contains('failed host lookup') ||
        text.contains('nodename nor servname') ||
        text.contains('name or service not known') ||
        (os != null && dnsErrnos.contains(os.errorCode))) {
      return UqpayTransportFailureKind.dns;
    }
    return UqpayTransportFailureKind.socket;
  }
  if (error is http.ClientException) {
    return UqpayTransportFailureKind.socket;
  }
  return null;
}
