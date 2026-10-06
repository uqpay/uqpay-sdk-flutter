/// Build-time configuration for the sample app.
///
/// Everything here arrives through `--dart-define-from-file=app.env`, a
/// file `example/tool/app_env.sh` generates from `.env` with only the three
/// keys below. **No credential is ever among them**: the API key and client
/// id belong on the merchant backend, the SDK has no parameter that accepts
/// one, and `test/config_test.dart` fails if this app ever reads one.
library;

import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

const String _rawEnvironment = String.fromEnvironment(
  'UQPAY_ENVIRONMENT',
  defaultValue: 'sandbox',
);

const String _rawBackendUrl = String.fromEnvironment(
  'UQPAY_MERCHANT_BACKEND_URL',
  defaultValue: AppConfig.defaultBackendUrl,
);

const String _rawOnBehalfOf = String.fromEnvironment('UQPAY_ON_BEHALF_OF');

/// The resolved, immutable configuration of one run of the sample app.
class AppConfig {
  const AppConfig({
    required this.configuredEnvironment,
    required this.backendBaseUrl,
    required this.onBehalfOf,
    required this.rawEnvironment,
    required this.rawBackendUrl,
    required this.environmentRecognised,
    required this.backendUrlRecognised,
  });

  /// Reads the three `--dart-define` keys the app supports.
  factory AppConfig.fromEnvironment() => AppConfig.resolve(
    environment: _rawEnvironment,
    backendUrl: _rawBackendUrl,
    onBehalfOf: _rawOnBehalfOf,
  );

  /// Resolves raw strings into a configuration, tolerating anything.
  ///
  /// An unrecognised environment name falls back to
  /// [UqpayEnvironment.sandbox] and is reported through
  /// [environmentRecognised] — a typo must never silently target production.
  /// An unusable backend URL falls back to [defaultBackendUrl] and is
  /// reported through [backendUrlRecognised].
  factory AppConfig.resolve({
    required String environment,
    required String backendUrl,
    required String onBehalfOf,
  }) {
    final envName = environment.trim().toLowerCase();
    final matched = switch (envName) {
      'sandbox' => UqpayEnvironment.sandbox,
      'production' || 'prod' || 'live' => UqpayEnvironment.production,
      _ => null,
    };
    final url = _normaliseUrl(backendUrl);
    return AppConfig(
      configuredEnvironment: matched ?? UqpayEnvironment.sandbox,
      backendBaseUrl: url ?? defaultBackendUrl,
      onBehalfOf: onBehalfOf.trim().isEmpty ? null : onBehalfOf.trim(),
      rawEnvironment: environment,
      rawBackendUrl: backendUrl,
      environmentRecognised: matched != null,
      backendUrlRecognised: url != null,
    );
  }

  /// Where `example/backend` listens by default.
  static const String defaultBackendUrl = 'http://localhost:8787';

  /// The environment named by `UQPAY_ENVIRONMENT`, sandbox when unreadable.
  final UqpayEnvironment configuredEnvironment;

  /// Origin of the merchant backend, with no trailing slash.
  final String backendBaseUrl;

  /// Connected sub-account id from `UQPAY_ON_BEHALF_OF`, or `null`.
  final String? onBehalfOf;

  /// The literal `UQPAY_ENVIRONMENT` value, for display.
  final String rawEnvironment;

  /// The literal `UQPAY_MERCHANT_BACKEND_URL` value, for display.
  final String rawBackendUrl;

  /// Whether [rawEnvironment] named an environment this app knows.
  final bool environmentRecognised;

  /// Whether [rawBackendUrl] parsed as an absolute http(s) origin.
  final bool backendUrlRecognised;

  /// Whether the build asked for production. The runtime switch still starts
  /// on sandbox; this only drives the on-screen note.
  bool get productionRequested =>
      configuredEnvironment == UqpayEnvironment.production;

  /// True when the backend URL points at the loopback interface, which an
  /// Android emulator or a physical device cannot reach.
  bool get backendIsLoopback {
    final host = Uri.tryParse(backendBaseUrl)?.host.toLowerCase() ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  static String? _normaliseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
