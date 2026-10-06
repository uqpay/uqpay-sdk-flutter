/// Backend configuration, read from environment variables whose names match
/// the repo-root `env.template` exactly.
library;

import 'dart:io' show InternetAddress;

import 'cors.dart';

/// Thrown when the environment is missing or unsafe. The message names the
/// offending variable so the operator can fix it; it never contains a value.
class ConfigError implements Exception {
  ConfigError(this.message);

  final String message;

  @override
  String toString() => 'ConfigError: $message';
}

/// Immutable server configuration.
class BackendConfig {
  BackendConfig({
    required this.environment,
    required this.clientId,
    required this.apiKey,
    required this.apiBaseUrl,
    required this.port,
    this.onBehalfOf,
    this.webhookUrl,
    this.bindAddress = defaultBindAddress,
    CorsPolicy? cors,
  }) : cors = cors ?? CorsPolicy.localDev;

  /// Parses `env`. Throws [ConfigError] on a missing credential or an
  /// unguarded production environment.
  factory BackendConfig.fromEnvironment(Map<String, String> env) {
    String? read(String name) {
      final v = env[name]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    final environment = (read('UQPAY_ENVIRONMENT') ?? 'sandbox').toLowerCase();
    if (environment != 'sandbox' && environment != 'production') {
      throw ConfigError(
        'UQPAY_ENVIRONMENT must be "sandbox" or "production" '
        '(got "$environment").',
      );
    }
    if (environment == 'production' && read('UQPAY_ALLOW_PRODUCTION') != '1') {
      throw ConfigError(
        'UQPAY_ENVIRONMENT=production refused: this is a demo server. '
        'Set UQPAY_ALLOW_PRODUCTION=1 to override (not recommended).',
      );
    }

    final clientId = read('UQPAY_CLIENT_ID');
    if (clientId == null) {
      throw ConfigError(
        'UQPAY_CLIENT_ID is not set. Copy env.template to .env and fill it in.',
      );
    }
    final apiKey = read('UQPAY_API_KEY');
    if (apiKey == null) {
      throw ConfigError(
        'UQPAY_API_KEY is not set. Copy env.template to .env and fill it in.',
      );
    }

    final override = read('UQPAY_API_BASE_URL_OVERRIDE');
    final Uri apiBaseUrl;
    if (override != null) {
      final parsed = Uri.tryParse(override);
      if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
        throw ConfigError(
          'UQPAY_API_BASE_URL_OVERRIDE must be an https origin.',
        );
      }
      apiBaseUrl = parsed;
    } else {
      apiBaseUrl = defaultBaseUrl(environment);
    }

    final portRaw = read('PORT') ?? read('UQPAY_BACKEND_PORT');
    final port = portRaw == null ? defaultPort : int.tryParse(portRaw);
    if (port == null || port < 1 || port > 65535) {
      throw ConfigError('PORT must be an integer between 1 and 65535.');
    }

    // Loopback unless the developer explicitly opts in: on 0.0.0.0 anyone on
    // the same network can ask this server for the merchant token.
    final bindAddress = read('UQPAY_BACKEND_BIND') ?? defaultBindAddress;
    if (InternetAddress.tryParse(bindAddress) == null) {
      throw ConfigError(
        'UQPAY_BACKEND_BIND must be an IP address such as 127.0.0.1 '
        '(the default) or 0.0.0.0.',
      );
    }

    final CorsPolicy cors;
    final corsRaw = read('UQPAY_BACKEND_CORS_ORIGINS');
    try {
      cors = corsRaw == null
          ? CorsPolicy.localDev
          : CorsPolicy.parse(corsRaw.split(','));
    } on CorsConfigError catch (e) {
      throw ConfigError('UQPAY_BACKEND_CORS_ORIGINS: ${e.message}');
    }
    if (cors.entries.isEmpty) {
      throw ConfigError(
        'UQPAY_BACKEND_CORS_ORIGINS is empty; unset it for the localhost '
        'default.',
      );
    }

    return BackendConfig(
      environment: environment,
      clientId: clientId,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      port: port,
      onBehalfOf: read('UQPAY_ON_BEHALF_OF'),
      webhookUrl: read('UQPAY_WEBHOOK_URL'),
      bindAddress: bindAddress,
      cors: cors,
    );
  }

  static const int defaultPort = 8787;

  /// Loopback only. `UQPAY_BACKEND_BIND=0.0.0.0` opts in to every interface
  /// (needed for a physical device on the LAN).
  static const String defaultBindAddress = '127.0.0.1';

  /// UQPAY API hosts per environment.
  static Uri defaultBaseUrl(String environment) => switch (environment) {
    'production' => Uri.parse('https://api.uqpay.com'),
    _ => Uri.parse('https://api-sandbox.uqpaytech.com'),
  };

  final String environment;
  final String clientId;
  final String apiKey;
  final Uri apiBaseUrl;
  final int port;
  final String? onBehalfOf;
  final String? webhookUrl;

  /// The IP address the server listens on.
  final String bindAddress;

  /// Browser origins allowed to call the server.
  final CorsPolicy cors;

  /// True when [bindAddress] is not a loopback address, i.e. the server is
  /// reachable from other machines.
  bool get reachableFromNetwork =>
      !(InternetAddress.tryParse(bindAddress)?.isLoopback ?? false);
}

/// The lines printed when the server starts. The first one is the warning
/// every run must show: this server hands its merchant token to anyone who
/// asks, so it is for local development only.
List<String> startupBanner(BackendConfig config) => [
  '*** UQPAY reference backend: local development only — never deploy this '
      'server. ***',
  'It hands the merchant token to any caller that can reach it, with no user '
      'session; a real backend authenticates the user and computes amounts '
      'server-side.',
  if (config.reachableFromNetwork)
    'WARNING: listening on ${config.bindAddress} (UQPAY_BACKEND_BIND): any '
        'machine on this network can request the merchant token. Use only on '
        'a trusted network.',
  'cors: browser origins allowed: ${config.cors.entries.join(', ')}',
];

/// Masks a secret for logging: only the last four characters survive.
String mask(String? value) {
  if (value == null || value.isEmpty) return '<unset>';
  if (value.length <= 4) return '****';
  return '****${value.substring(value.length - 4)}';
}
