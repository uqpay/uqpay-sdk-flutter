import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// A `dart:io` client that ignores `HttpOverrides.global`.
///
/// Apps commonly install a global override during development that accepts
/// every certificate (`badCertificateCallback`) or routes through a proxy.
/// The payment connection must not inherit either, so the SDK builds its
/// `HttpClient` under a plain override that only ever creates the stock
/// client: certificate validation stays the platform's, and no proxy is
/// consulted.
http.Client createDefaultInnerClient() => IOClient(
  HttpOverrides.runWithHttpOverrides(HttpClient.new, _PlainOverrides()),
);

/// Deliberately overrides nothing: `HttpClient()` created under it is the
/// stock implementation, whatever `HttpOverrides.global` says.
class _PlainOverrides extends HttpOverrides {}
