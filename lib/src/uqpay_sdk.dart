import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payments.dart';
import 'package:uqpay_sdk_flutter/src/platform_support.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_token_provider.dart';
import 'package:uqpay_sdk_flutter/src/uqpay_environment.dart';

/// The entry point to the UQPAY SDK: a validated, immutable handle to one
/// configured environment.
///
/// Create one with [UqpaySdk.init] and keep it wherever your app keeps its
/// long-lived services. The SDK holds **no** global mutable state, so a Dart
/// hot restart cannot leave it half-initialised and two handles for two
/// different environments can coexist in the same isolate.
///
/// ```dart
/// final uqpay = UqpaySdk.init(
///   environment: UqpayEnvironment.sandbox,
///   tokenProvider: () async => UqpayAuthToken.fromJson(
///     await myBackend.fetchUqpayToken(),
///   ),
/// );
/// ```
///
/// The SDK never takes an API key. Payments are authorised with a short-lived
/// auth token your own backend obtains from UQPAY and hands to the app
/// through [tokenProvider] — see the Security section of the README.
///
/// The payment operations live on [payments]:
///
/// ```dart
/// final result = await uqpay.payments.confirm(intentId, request);
/// ```
@immutable
class UqpaySdk {
  UqpaySdk._({
    required this.environment,
    required this.baseUrl,
    required this.tokenProvider,
    required this.clientId,
    required this.onBehalfOf,
    required this.loggingEnabled,
    required this.logHandler,
  });

  /// Validates the configuration and returns a handle to the configured SDK.
  ///
  /// Calling this more than once is safe and does nothing surprising: it
  /// performs no I/O, starts no timers and mutates no global state, so two
  /// calls with the same arguments produce two equal handles. Call
  /// it again with different arguments to switch environments.
  ///
  /// Throws an [UnsupportedError] naming the platform when called on desktop,
  /// which this SDK does not support. Throws an [ArgumentError] naming the
  /// offending field when the configuration is invalid — never later, mid
  /// payment.
  ///
  /// [tokenProvider] supplies the auth token from your backend. It may be
  /// omitted while wiring up an app, but any operation that talks to the API
  /// throws an [ArgumentError] naming `tokenProvider` before sending anything.
  ///
  /// [clientId] is your UQPAY client id, sent as `x-client-id`. It is an
  /// identifier, not a secret; leave it unset if your token alone identifies
  /// the merchant.
  ///
  /// [onBehalfOf] is a connected sub-account id, sent as `x-on-behalf-of` on
  /// every request when set (UQPAY Connect platforms only).
  ///
  /// [baseUrlOverride] replaces the origin derived from [environment]. It
  /// exists for pointing the SDK at a non-standard UQPAY deployment and must be
  /// an absolute `https` origin such as `https://api.example.com`; `http://`
  /// is refused here. Leave it unset in production apps.
  ///
  /// [loggingEnabled] turns on diagnostic logging (default off). When on,
  /// the SDK logs the HTTP method, path and status code of every request,
  /// the `x-trace-id` to quote to support, the intent id, every flow phase
  /// transition and the class name of any unexpected exception — and
  /// **never** a request or response body, card number, CVC, expiry,
  /// cardholder name or token. Lines go to [logHandler] when supplied, else
  /// to `dart:developer` under the name `uqpay`. Keep it off in release
  /// builds unless you route [logHandler] to your own redacted logger.
  static UqpaySdk init({
    required UqpayEnvironment environment,
    UqpayTokenProvider? tokenProvider,
    String? clientId,
    String? onBehalfOf,
    String? baseUrlOverride,
    bool loggingEnabled = false,
    void Function(String line)? logHandler,
  }) {
    final unsupported = unsupportedPlatformName();
    if (unsupported != null) {
      throw UnsupportedError(
        'The UQPAY Flutter SDK does not support $unsupported. Supported '
        'platforms are Android, iOS and web.',
      );
    }

    return UqpaySdk._(
      environment: environment,
      baseUrl: _resolveBaseUrl(environment, baseUrlOverride),
      tokenProvider: tokenProvider,
      clientId: _optionalNonBlank(clientId, 'clientId'),
      onBehalfOf: _optionalNonBlank(onBehalfOf, 'onBehalfOf'),
      loggingEnabled: loggingEnabled,
      logHandler: logHandler,
    );
  }

  /// The environment this handle talks to.
  final UqpayEnvironment environment;

  /// The HTTPS origin this handle sends requests to, without a trailing slash.
  ///
  /// Equal to [UqpayEnvironment.baseUrl] unless a `baseUrlOverride` was passed
  /// to [UqpaySdk.init].
  final String baseUrl;

  /// The merchant-supplied token provider, or `null` when not configured.
  final UqpayTokenProvider? tokenProvider;

  /// The merchant's UQPAY client id, sent as `x-client-id` when set.
  final String? clientId;

  /// The connected sub-account acted on behalf of, sent as `x-on-behalf-of`
  /// when set.
  final String? onBehalfOf;

  /// Whether diagnostic logging is on. See [UqpaySdk.init].
  final bool loggingEnabled;

  /// Receives each diagnostic line when [loggingEnabled] is true; `null`
  /// sends them to `dart:developer` instead.
  final void Function(String line)? logHandler;

  /// Whether [baseUrl] came from a `baseUrlOverride` rather than from
  /// [environment].
  bool get usesCustomBaseUrl => baseUrl != environment.baseUrl;

  /// The headless payment API for this handle: retrieve, confirm, await,
  /// reconcile and cancel intents.
  ///
  /// Created on first access and cached on this handle — no global state,
  /// so a hot restart (which re-runs `init`) starts clean. Throws
  /// [ArgumentError] naming `tokenProvider` on first access when
  /// [UqpaySdk.init] was called without one; accessing it performs
  /// no I/O.
  late final UqpayPayments payments = UqpayPayments.forSdk(this);

  static String? _optionalNonBlank(String? value, String field) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        value,
        field,
        'must not be empty — omit it instead',
      );
    }
    if (!RegExp(r'^[\x21-\x7E]+$').hasMatch(trimmed)) {
      throw ArgumentError.value(
        value,
        field,
        'must contain only visible ASCII characters (it is sent as an HTTP '
        'header)',
      );
    }
    return trimmed;
  }

  static String _resolveBaseUrl(
    UqpayEnvironment environment,
    String? baseUrlOverride,
  ) {
    if (baseUrlOverride == null) {
      return environment.baseUrl;
    }

    final trimmed = baseUrlOverride.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        baseUrlOverride,
        'baseUrlOverride',
        'must not be empty — omit it to use the origin for '
            'UqpayEnvironment.${environment.name}',
      );
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      throw ArgumentError.value(
        baseUrlOverride,
        'baseUrlOverride',
        'must be an absolute origin, for example https://api.example.com',
      );
    }
    // HTTPS only, refused at configuration time rather than at send
    // time, so a misconfiguration can never leak a request in the clear.
    if (uri.scheme != 'https') {
      throw ArgumentError.value(
        baseUrlOverride,
        'baseUrlOverride',
        'must use https, not ${uri.scheme}',
      );
    }
    // A bare origin only. Userinfo would let `https://api.uqpay.com@evil`
    // send every request (and the token) to `evil`; a query or fragment
    // would be glued onto every request path; a path would silently change
    // every endpoint.
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError.value(
        baseUrlOverride,
        'baseUrlOverride',
        'must be a bare https origin (scheme + host + optional port) with no '
            'path, query, fragment or credentials',
      );
    }

    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is UqpaySdk &&
      other.environment == environment &&
      other.baseUrl == baseUrl &&
      other.tokenProvider == tokenProvider &&
      other.clientId == clientId &&
      other.onBehalfOf == onBehalfOf;

  @override
  int get hashCode =>
      Object.hash(environment, baseUrl, tokenProvider, clientId, onBehalfOf);

  @override
  String toString() =>
      'UqpaySdk(environment: ${environment.name}, '
      'baseUrl: $baseUrl)';
}
