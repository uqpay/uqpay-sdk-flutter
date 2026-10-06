/// A tiny client for the reference merchant backend in `example/backend`.
///
/// This is the piece a real merchant replaces with their own server. The app
/// never talks to UQPAY with an API key — it asks this backend for a
/// short-lived auth token and for payment intents.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// Anything the merchant backend could not do, in a form the UI can show.
class MerchantBackendException implements Exception {
  /// Creates a backend failure.
  const MerchantBackendException({
    required this.summary,
    required this.detail,
    this.isUnreachable = false,
    this.traceId,
  });

  /// One line, safe for a headline.
  final String summary;

  /// The actionable part — what the tester should do about it.
  final String detail;

  /// Whether nothing answered at all (as opposed to answering an error).
  final bool isUnreachable;

  /// `x-trace-id` from the proxied UQPAY response, when there was one.
  final String? traceId;

  @override
  String toString() => '$summary — $detail';
}

/// One webhook delivery as `GET /webhooks/recent` reports it.
class WebhookEventView {
  /// Creates a view of a stored webhook.
  const WebhookEventView({
    required this.receivedAt,
    required this.eventType,
    required this.paymentIntentId,
    required this.status,
  });

  /// Reads one entry of the backend's `events` array.
  factory WebhookEventView.fromJson(Map<String, Object?> json) {
    final received = json['received_at'];
    return WebhookEventView(
      receivedAt: received is String ? received : '',
      eventType: json['event_type'] is String
          ? json['event_type']! as String
          : null,
      paymentIntentId: json['payment_intent_id'] is String
          ? json['payment_intent_id']! as String
          : null,
      status: json['status'] is String ? json['status']! as String : null,
    );
  }

  /// ISO-8601 timestamp the backend stamped on arrival.
  final String receivedAt;

  /// UQPAY's event type, when the payload carried one.
  final String? eventType;

  /// The intent the event is about, when the payload carried one.
  final String? paymentIntentId;

  /// The intent status the event reported, when present.
  final String? status;
}

/// HTTP client for the endpoints `example/backend/README.md` documents.
class MerchantBackend {
  /// Creates a client for the backend at [baseUrl].
  MerchantBackend({
    required this.baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _client = httpClient ?? http.Client();

  /// Origin of the backend, without a trailing slash.
  final String baseUrl;

  /// How long any single call may take before it counts as unreachable.
  final Duration timeout;

  final http.Client _client;

  String? _clientId;
  String? _lastToken;

  /// The `client_id` the backend disclosed, if it discloses one.
  ///
  /// UQPAY's API may require an `x-client-id` header; when the backend hands
  /// the id over the app passes it to [UqpaySdk.init] so the header is always
  /// present. The reference backend keeps it server-side, so this usually
  /// stays `null` — which is fine, the token alone identifies the merchant.
  String? get clientId => _clientId;

  /// `GET /health` — returns the environment the backend is configured for.
  Future<String> health() async {
    final json = await _json('GET', '/health');
    final environment = json['environment'];
    return environment is String ? environment : 'unknown';
  }

  /// `POST /client-token` — the short-lived token the SDK authenticates with.
  ///
  /// Wire this straight into `UqpaySdk.init(tokenProvider: ...)`: the SDK
  /// caches it, de-duplicates concurrent calls and calls back here on 401.
  ///
  /// UQPAY allows one active token per merchant, so when the SDK asks again
  /// the token it last received has most likely been invalidated by another
  /// issuer. Every call after the first therefore tells the backend which
  /// token was rejected — by its last four characters only, never the whole
  /// value — so the backend can mint a fresh one instead of replaying its
  /// cache.
  Future<UqpayAuthToken> authToken() async {
    final previous = _lastToken;
    final json = await _json(
      'POST',
      '/client-token',
      body: previous == null
          ? null
          : <String, Object?>{'rejected_token_suffix': _suffixOf(previous)},
    );
    final id = json['client_id'];
    if (id is String && id.trim().isNotEmpty) {
      _clientId = id.trim();
    }
    try {
      final token = UqpayAuthToken.fromJson(json);
      _lastToken = token.value;
      return token;
    } on FormatException catch (error) {
      throw MerchantBackendException(
        summary: 'The backend returned a token this app cannot read',
        detail:
            'POST /client-token must answer with '
            '{"auth_token":"…","expired_at":<epoch seconds>}. '
            '${error.message}',
      );
    }
  }

  /// `POST /payment-intents` — creates the intent server-side.
  ///
  /// [amount] is a **decimal string in major units** (`"8.98"`) and travels
  /// byte-for-byte: the app never scales it and neither does the backend.
  Future<UqpayPaymentIntent> createIntent({
    required String amount,
    required String currency,
    required Uri returnUrl,
    String? description,
    String? merchantOrderId,
  }) async {
    final json = await _json(
      'POST',
      '/payment-intents',
      body: <String, Object?>{
        'amount': amount,
        'currency': currency,
        'return_url': returnUrl.toString(),
        if (description != null && description.isNotEmpty)
          'description': description,
        'merchant_order_id': ?merchantOrderId,
      },
    );
    return _intentFrom(json);
  }

  /// `GET /payment-intents/{id}` — the server's own view of the intent.
  ///
  /// The sample app shows this next to the SDK's result to make the point
  /// that the server, not the client, is the source of truth.
  Future<UqpayPaymentIntent> fetchIntent(String intentId) async =>
      _intentFrom(await _json('GET', '/payment-intents/$intentId'));

  /// `GET /webhooks/recent` — the deliveries the backend has seen, newest
  /// first.
  Future<List<WebhookEventView>> recentWebhooks() async {
    final json = await _json('GET', '/webhooks/recent');
    final events = json['events'];
    if (events is! List) {
      return const <WebhookEventView>[];
    }
    return <WebhookEventView>[
      for (final event in events)
        if (event is Map<String, Object?>) WebhookEventView.fromJson(event),
    ];
  }

  /// Releases the underlying connections.
  void close() => _client.close();

  /// The last four characters of [token] — enough for the backend to tell
  /// whether its cached token is the rejected one, and never enough to use.
  static String _suffixOf(String token) =>
      token.length <= 4 ? token : token.substring(token.length - 4);

  UqpayPaymentIntent _intentFrom(Map<String, Object?> json) {
    try {
      return UqpayPaymentIntent.fromJson(json);
    } on FormatException catch (error) {
      throw MerchantBackendException(
        summary: 'UQPAY answered with something this app cannot read',
        detail:
            'The payment intent was missing a required field: '
            '${error.message}',
      );
    }
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final http.Response response;
    try {
      response = await switch (method) {
        'POST' => _client.post(
          uri,
          headers: const <String, String>{
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: body == null ? null : jsonEncode(body),
        ),
        _ => _client.get(
          uri,
          headers: const <String, String>{'accept': 'application/json'},
        ),
      }.timeout(timeout);
    } on Object catch (error) {
      throw MerchantBackendException(
        summary: 'Cannot reach the merchant backend',
        detail: unreachableHelp(baseUrl: baseUrl, error: error),
        isUnreachable: true,
      );
    }

    final traceId = response.headers['x-trace-id'];
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    final json = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = json['message'];
      final code = json['code'];
      throw MerchantBackendException(
        summary:
            '$method $path failed with HTTP ${response.statusCode}'
            '${code is String ? ' ($code)' : ''}',
        detail: message is String && message.isNotEmpty
            ? message
            : 'The backend logged the details; its console is the place to '
                  'look. Quote the trace id below to UQPAY support.',
        traceId: traceId,
      );
    }
    if (decoded == null) {
      throw MerchantBackendException(
        summary: '$method $path returned a body this app cannot read',
        detail: 'Expected a JSON object.',
        traceId: traceId,
      );
    }
    return json;
  }
}

/// The message shown when nothing answers at [baseUrl].
///
/// This is the single most likely thing to go wrong on a first run, so it
/// says exactly which command starts the backend and how to reach it from an
/// emulator or a physical device.
String unreachableHelp({required String baseUrl, Object? error}) =>
    'Nothing answered at $baseUrl'
    '${error == null ? '' : ' (${error.runtimeType})'}.\n\n'
    'Start the reference merchant backend first:\n'
    '    cd example/backend && tool/run.sh\n\n'
    'It listens on http://localhost:8787. An Android emulator reaches your '
    'machine at http://10.0.2.2:8787 and a physical device needs your LAN '
    'IP — set UQPAY_MERCHANT_BACKEND_URL in .env accordingly, then rerun '
    'flutter run with --dart-define-from-file=app.env (see tool/app_env.sh).';
