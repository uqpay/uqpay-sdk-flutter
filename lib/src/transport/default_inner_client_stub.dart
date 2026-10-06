import 'package:http/http.dart' as http;

/// The platform default `package:http` client (web and other non-`dart:io`
/// targets): the browser owns TLS, so nothing can be overridden here.
http.Client createDefaultInnerClient() => http.Client();
