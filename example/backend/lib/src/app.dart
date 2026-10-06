/// HTTP surface consumed by the sample app.
library;

import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'token_manager.dart';
import 'uqpay_client.dart';
import 'webhook_store.dart';

const _jsonHeaders = {'Content-Type': 'application/json; charset=utf-8'};

/// Wires config, token manager and upstream client into a shelf [Handler].
class BackendApp {
  BackendApp({
    required this.config,
    required this.tokens,
    required this.uqpay,
    WebhookStore? webhooks,
    DateTime Function()? clock,
    Random? random,
    void Function(String line)? log,
  }) : webhooks = webhooks ?? WebhookStore(),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _log = log ?? ((_) {});

  final BackendConfig config;
  final TokenManager tokens;
  final UqpayClient uqpay;
  final WebhookStore webhooks;
  final DateTime Function() _clock;
  final Random _random;
  final void Function(String line) _log;

  Handler get handler {
    final router = Router(notFoundHandler: (_) => _error(404, 'not_found'))
      ..get('/health', _health)
      ..post('/client-token', _clientToken)
      ..post('/payment-intents', _createIntent)
      ..get('/payment-intents/<id>', _getIntent)
      ..post('/webhooks/uqpay', _webhook)
      ..get('/webhooks/recent', _recentWebhooks);

    return const Pipeline()
        .addMiddleware(_cors)
        .addMiddleware(_catchErrors)
        .addHandler(router.call);
  }

  // ---------------------------------------------------------------- routes

  Response _health(Request _) =>
      _json(200, {'ok': true, 'environment': config.environment});

  /// Hands the app the short-lived merchant token (the app holds a
  /// token, never the API key).
  ///
  /// A real merchant backend would NOT hand out the raw merchant token to any
  /// anonymous caller: it would authenticate the app user's session first,
  /// and ideally scope what it returns to a single payment (e.g. return only
  /// the intent id + token right after creating the intent, or rotate/limit
  /// the token per session). This endpoint is intentionally simple for the
  /// sample app.
  ///
  /// Optional JSON body `{"rejected_token_suffix": "<last 4 chars>"}`: the
  /// app sends it when the SDK asks for a token again, naming the one it was
  /// refused with. If that is the cached token, it has been invalidated by
  /// another issuer and a fresh one is minted (single-flight) instead of
  /// replaying the dead one. Only the suffix ever crosses the wire.
  Future<Response> _clientToken(Request request) async {
    final text = await request.readAsString();
    String? rejectedSuffix;
    if (text.trim().isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        return _error(400, 'invalid_json', 'request body must be JSON');
      }
      if (decoded is! Map<String, Object?>) {
        return _error(
          400,
          'invalid_json',
          'request body must be a JSON object',
        );
      }
      final suffix = decoded['rejected_token_suffix'];
      if (suffix != null && (suffix is! String || suffix.length != 4)) {
        return _error(
          400,
          'invalid_rejected_token_suffix',
          'rejected_token_suffix must be the last four characters of the '
              'token that was refused',
        );
      }
      rejectedSuffix = suffix as String?;
    }
    final token = await tokens.getToken(rejectedTokenSuffix: rejectedSuffix);
    return _json(200, {
      'token': token.value,
      'expires_at': token.expiresAt.toUtc().toIso8601String(),
      // Same data in UQPAY's own token-response shape (`auth_token`,
      // `expired_at`), for clients written against that shape.
      'auth_token': token.value,
      'expired_at': token.expiresAt.millisecondsSinceEpoch ~/ 1000,
      // The client id is NOT a secret (the API key is), and the iOS SDK sends
      // it as `x-client-id` on every call. The sandbox accepts confirms
      // without it; we hand it over anyway and let the app pass it as
      // `clientId` — sending it costs nothing and removes the risk that a
      // confirm fails with a misleading `authentication_failed`.
      'client_id': config.clientId,
    });
  }

  /// Proxies `POST /api/v2/payment_intents/create`.
  ///
  /// `amount` MUST be a decimal string in MAJOR units (`"8.98"`). It is
  /// forwarded byte-for-byte: no scaling, no rounding, no reformatting.
  ///
  /// DEMO SHORTCUT: this sample lets the app choose `amount` and `currency`
  /// so a tester can try any value. A real merchant backend NEVER takes the
  /// amount from the client: the app sends an order reference, and the
  /// server computes amount and currency from its own order record (cart,
  /// prices, tax, discounts) before creating the intent. Anything else lets a
  /// customer pay 0.01 for any order.
  ///
  /// Only the fields in [_allowedIntentFields] are accepted; anything else is
  /// refused, so a client cannot set gateway fields (capture mode, customer,
  /// payment method options, ...) this demo never meant to expose.
  Future<Response> _createIntent(Request request) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      return _error(400, 'invalid_json', 'request body must be JSON');
    }
    if (decoded is! Map<String, Object?>) {
      return _error(400, 'invalid_json', 'request body must be a JSON object');
    }
    final unknown = decoded.keys
        .where((k) => !_allowedIntentFields.contains(k))
        .toList();
    if (unknown.isNotEmpty) {
      return _error(
        400,
        'unknown_field',
        'only ${_allowedIntentFields.join(', ')} may be sent '
            '(${unknown.length} other field(s) refused)',
      );
    }
    for (final field in const ['return_url', 'merchant_order_id']) {
      final value = decoded[field];
      if (value != null && (value is! String || value.isEmpty)) {
        return _error(
          400,
          'invalid_$field',
          '$field must be a non-empty string',
        );
      }
    }
    final metadata = decoded['metadata'];
    if (metadata != null && metadata is! Map<String, Object?>) {
      return _error(400, 'invalid_metadata', 'metadata must be a JSON object');
    }
    final amount = decoded['amount'];
    if (amount is! String || !_amountPattern.hasMatch(amount)) {
      return _error(
        400,
        'invalid_amount',
        'amount must be a decimal string in major units, e.g. "8.98" '
            '(never cents, never a JSON number)',
      );
    }
    final currency = decoded['currency'];
    if (currency is! String || currency.length != 3) {
      return _error(400, 'invalid_currency', 'currency must be ISO 4217');
    }
    // description is required upstream and capped at 32 characters. Both facts
    // are worth catching here, because the gateway rejects a violation with a
    // bare `invalid_parameter` that does not name the offending field.
    final description = decoded['description'];
    if (description != null &&
        (description is! String ||
            description.trim().isEmpty ||
            description.length > _descriptionMaxLength)) {
      return _error(
        400,
        'invalid_description',
        'description must be a non-empty string of at most '
            '$_descriptionMaxLength characters',
      );
    }
    // merchant_order_id is required upstream; mint one if the app did
    // not supply its own. description is required too, so it gets the same
    // treatment — a demo that cannot create an intent teaches nothing.
    final merchantOrderId =
        decoded['merchant_order_id'] ?? newIdempotencyKey(_random);
    final body = <String, Object?>{
      ...decoded,
      'merchant_order_id': merchantOrderId,
      'description': description ?? _defaultDescription(merchantOrderId),
    };
    final upstream = await uqpay.createPaymentIntent(jsonEncode(body));
    _log(
      'intent: create -> ${upstream.statusCode}'
      '${_intentIdOf(upstream)}'
      '${upstream.traceId == null ? '' : ' trace=${upstream.traceId}'}',
    );
    return _proxied(upstream);
  }

  /// Proxies `GET /api/v2/payment_intents/{id}`.
  Future<Response> _getIntent(Request request, String id) async {
    final upstream = await uqpay.getPaymentIntent(id);
    _log(
      'intent: get $id -> ${upstream.statusCode}'
      '${upstream.traceId == null ? '' : ' trace=${upstream.traceId}'}',
    );
    return _proxied(upstream);
  }

  /// Receives UQPAY webhooks. This is how the 3DS outcome reaches the
  /// merchant; the client result is only a UX signal.
  Future<Response> _webhook(Request request) async {
    final text = await request.readAsString();
    Object? payload;
    try {
      payload = jsonDecode(text);
    } on FormatException {
      payload = {'_unparsed': true};
    }
    final event = WebhookEvent.fromPayload(payload, _clock());
    webhooks.add(event);
    _log(event.summary);
    return _json(200, {'received': true});
  }

  Response _recentWebhooks(Request _) =>
      _json(200, {'events': webhooks.recent.map((e) => e.toJson()).toList()});

  // -------------------------------------------------------------- helpers

  static final _amountPattern = RegExp(r'^\d+(\.\d+)?$');

  /// The only client fields `POST /payment-intents` accepts.
  static const _allowedIntentFields = {
    'amount',
    'currency',
    'return_url',
    'description',
    'merchant_order_id',
    'metadata',
  };

  /// The gateway's own limit on `description`.
  static const _descriptionMaxLength = 32;

  /// A stand-in description for a request that did not carry one, kept inside
  /// [_descriptionMaxLength] whatever the order id looks like.
  static String _defaultDescription(Object? merchantOrderId) {
    const prefix = 'Order ';
    final id = '$merchantOrderId';
    final room = _descriptionMaxLength - prefix.length;
    return '$prefix${id.length <= room ? id : id.substring(0, room)}';
  }

  /// The created intent's id for the log line, so a tester can correlate a
  /// device run with a server-side intent. Never logs anything else from the
  /// body.
  static String _intentIdOf(UpstreamResponse upstream) {
    if (upstream.statusCode != 200) {
      return '';
    }
    try {
      final decoded = jsonDecode(upstream.body);
      final id = decoded is Map ? decoded['payment_intent_id'] : null;
      return id is String && id.isNotEmpty ? ' id=$id' : '';
    } on FormatException {
      return '';
    }
  }

  static Response _proxied(UpstreamResponse upstream) => Response(
    upstream.statusCode,
    body: upstream.body,
    headers: {..._jsonHeaders, 'x-trace-id': ?upstream.traceId},
  );

  static Response _json(int status, Map<String, Object?> body) =>
      Response(status, body: jsonEncode(body), headers: _jsonHeaders);

  static Response _error(int status, String code, [String? message]) =>
      _json(status, {
        'code': code,
        'type': status >= 500 ? 'api_error' : 'invalid_request_error',
        'message': message ?? code,
      });

  /// CORS by allow-list ([BackendConfig.cors], localhost dev origins by
  /// default). A request with no `Origin` header (the mobile app, curl) is
  /// served as usual. A browser request from an allowed origin gets that
  /// origin reflected. A browser request from any other origin is refused
  /// with 403 before it reaches a route — not just left unreadable — so a web
  /// page cannot even trigger side effects such as a forced token re-mint.
  Handler _cors(Handler inner) => (request) async {
    final origin = request.headers['origin'];
    if (origin != null && !config.cors.allows(origin)) {
      _log('cors: refused a request from a disallowed origin');
      return _error(
        403,
        'origin_not_allowed',
        'this origin is not in UQPAY_BACKEND_CORS_ORIGINS',
      ).change(headers: const {'Vary': 'Origin'});
    }
    final headers = {..._corsHeaders, 'Access-Control-Allow-Origin': ?origin};
    if (request.method == 'OPTIONS') {
      return Response(204, headers: headers);
    }
    final response = await inner(request);
    return response.change(
      headers: origin == null ? const {'Vary': 'Origin'} : headers,
    );
  };

  Handler _catchErrors(Handler inner) => (request) async {
    try {
      return await inner(request);
    } on TokenIssueException catch (e) {
      _log('token: upstream refused (${e.statusCode}): ${e.message}');
      return _error(
        502,
        'token_issue_failed',
        'UQPAY refused to issue a token (${e.statusCode}): ${e.message}',
      );
    } catch (e) {
      // Never echo request contents; the message here is our own.
      _log('error: ${e.runtimeType}');
      return _error(502, 'upstream_error', e.runtimeType.toString());
    }
  };
}

/// Static CORS headers; `Access-Control-Allow-Origin` is added per request.
const _corsHeaders = {
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
  'Access-Control-Expose-Headers': 'x-trace-id',
  'Access-Control-Max-Age': '600',
  'Vary': 'Origin',
};
