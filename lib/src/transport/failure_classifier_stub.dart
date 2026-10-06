import 'package:http/http.dart' as http;
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

/// Classifies a low-level error on platforms without `dart:io` (web, both JS
/// and WebAssembly builds).
///
/// The browser exposes no DNS/TLS distinction — a failed `fetch` is opaque —
/// so every [http.ClientException] is a socket-level failure. Returns `null`
/// for errors that are not transport failures.
UqpayTransportFailureKind? classifyTransportError(Object error) {
  if (error is http.ClientException) {
    return UqpayTransportFailureKind.socket;
  }
  return null;
}
