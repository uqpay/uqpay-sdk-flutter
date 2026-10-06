import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uqpay_reference_backend/uqpay_reference_backend.dart';

Future<void> main() async {
  final BackendConfig config;
  try {
    config = BackendConfig.fromEnvironment(Platform.environment);
  } on ConfigError catch (e) {
    stderr.writeln('refusing to start: ${e.message}');
    exitCode = 64; // EX_USAGE
    return;
  }

  void log(String line) =>
      stdout.writeln('${DateTime.now().toUtc().toIso8601String()} $line');

  final httpClient = http.Client();
  final tokens = TokenManager(config: config, client: httpClient, log: log);
  final uqpay = UqpayClient(config: config, tokens: tokens, client: httpClient);
  final app = BackendApp(
    config: config,
    tokens: tokens,
    uqpay: uqpay,
    log: log,
  );

  // Loopback by default; UQPAY_BACKEND_BIND=0.0.0.0 is an explicit opt-in.
  final server = await serveBackend(config, app.handler);
  startupBanner(config).forEach(log);
  log(
    'uqpay reference backend listening on '
    'http://${config.bindAddress}:${server.port}',
  );
  log(
    'environment=${config.environment} api=${config.apiBaseUrl} '
    'client=${mask(config.clientId)} key=${mask(config.apiKey)} '
    'on_behalf_of=${config.onBehalfOf == null ? '-' : mask(config.onBehalfOf)} '
    'webhook_url=${config.webhookUrl ?? '-'}',
  );

  ProcessSignal.sigint.watch().first.then((_) async {
    log('shutting down');
    await server.close(force: true);
    httpClient.close();
    exit(0);
  });
}
