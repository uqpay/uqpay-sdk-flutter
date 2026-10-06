/// Starts the HTTP server on the configured address.
library;

import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'config.dart';

/// Serves [handler] on [BackendConfig.bindAddress] — loopback unless
/// `UQPAY_BACKEND_BIND` opted in to more — and [BackendConfig.port].
Future<HttpServer> serveBackend(BackendConfig config, Handler handler) =>
    shelf_io.serve(handler, InternetAddress(config.bindAddress), config.port);
