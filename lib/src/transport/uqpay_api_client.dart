import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/core/canonical_json.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_logger.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_confirm_request.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';
import 'package:uqpay_sdk_flutter/src/transport/token_cache.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/src/uqpay_sdk.dart';

/// The outcome of one API call: a decoded value or a mapped [UqpayError].
/// Never an exception.
@immutable
sealed class UqpayApiResult<T> {
  const UqpayApiResult();
}

/// A 2xx response whose body decoded successfully.
final class UqpayApiSuccess<T> extends UqpayApiResult<T> {
  /// Creates a success.
  const UqpayApiSuccess(this.value, {this.traceId, this.responseId});

  /// The decoded body.
  final T value;

  /// The response's `x-trace-id`, if any.
  final String? traceId;

  /// The response's `x-response-id`, if any.
  final String? responseId;
}

/// Anything else — transport failure, non-2xx, undecodable 2xx — as one
/// mapped error carrying the trace id when the server sent one.
final class UqpayApiFailure<T> extends UqpayApiResult<T> {
  /// Creates a failure.
  const UqpayApiFailure(this.error);

  /// The mapped error.
  final UqpayError error;
}

/// The SDK's transport to the intent endpoints (read, confirm and
/// cancel):
/// header assembly, auth-token caching with refresh-on-401 exactly once,
/// canonical body encoding, tolerant envelope decoding, and trace-id capture.
///
/// This class is internal. It performs no retries beyond the single 401
/// refresh and no polling; that logic lives in the payment flow (P2), which
/// decides what an outcome-unknown error means.
class UqpayApiClient {
  /// Creates a client for [sdk].
  ///
  /// Throws [ArgumentError] naming `tokenProvider` when [sdk] has none —
  /// before any request is built.
  UqpayApiClient({
    required UqpaySdk sdk,
    required UqpayHttpClient httpClient,
    required UqpayClock clock,
    this.requestTimeout = const Duration(seconds: 30),
    UqpayLogger logger = UqpayLogger.disabled,
  }) : _sdk = sdk,
       _httpClient = httpClient,
       _logger = logger,
       _tokens = TokenCache(
         provider:
             sdk.tokenProvider ??
             (throw ArgumentError.value(
               null,
               'tokenProvider',
               'UqpaySdk.init must be given a tokenProvider before the SDK '
                   'can call the UQPAY API',
             )),
         clock: clock,
       );

  final UqpaySdk _sdk;
  final UqpayHttpClient _httpClient;
  final TokenCache _tokens;
  final UqpayLogger _logger;

  /// Per-request timeout (the gateway's documented 30 s).
  final Duration requestTimeout;

  /// `GET /api/v2/payment_intents/{id}`.
  Future<UqpayApiResult<UqpayPaymentIntent>> retrievePaymentIntent(String id) {
    _requireId(id);
    return _send(
      method: 'GET',
      path: '/api/v2/payment_intents/${Uri.encodeComponent(id)}',
    );
  }

  /// `POST /api/v2/payment_intents/{id}/confirm` with [request] encoded with
  /// sorted keys and [idempotencyKey] as `x-idempotency-key`.
  ///
  /// The caller owns the key (see the idempotency store): a retry of the
  /// same logical attempt must pass the same key and an equal [request] so
  /// the bytes are identical.
  Future<UqpayApiResult<UqpayPaymentIntent>> confirmPaymentIntent({
    required String id,
    required UqpayConfirmRequest request,
    required String idempotencyKey,
  }) {
    _requireId(id);
    if (idempotencyKey.isEmpty) {
      throw ArgumentError.value('', 'idempotencyKey', 'must not be empty');
    }
    return _send(
      method: 'POST',
      path: '/api/v2/payment_intents/${Uri.encodeComponent(id)}/confirm',
      body: request.toCanonicalJson(),
      idempotencyKey: idempotencyKey,
    );
  }

  /// `POST /api/v2/payment_intents/{id}/cancel` with
  /// `{"cancellation_reason": …}` and a fresh [idempotencyKey].
  ///
  /// The endpoint is not part of the iOS wire contract (which calls only
  /// create / get / confirm); its path and body were taken from the UQPAY
  /// CLI. Whether a client auth token is authorised to cancel is **not yet
  /// verified against the sandbox** — a rejection surfaces as a mapped
  /// error, never a crash. Cancels are never auto-retried.
  Future<UqpayApiResult<UqpayPaymentIntent>> cancelPaymentIntent({
    required String id,
    required String cancellationReason,
    required String idempotencyKey,
  }) {
    _requireId(id);
    if (idempotencyKey.isEmpty) {
      throw ArgumentError.value('', 'idempotencyKey', 'must not be empty');
    }
    if (cancellationReason.trim().isEmpty) {
      throw ArgumentError.value(
        cancellationReason,
        'cancellationReason',
        'must not be empty',
      );
    }
    return _send(
      method: 'POST',
      path: '/api/v2/payment_intents/${Uri.encodeComponent(id)}/cancel',
      body: encodeCanonicalJson(<String, Object?>{
        'cancellation_reason': cancellationReason,
      }),
      idempotencyKey: idempotencyKey,
    );
  }

  static void _requireId(String id) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'paymentIntentId', 'must not be empty');
    }
  }

  Future<UqpayApiResult<UqpayPaymentIntent>> _send({
    required String method,
    required String path,
    String? body,
    String? idempotencyKey,
  }) async {
    final url = Uri.parse('${_sdk.baseUrl}$path');

    UqpayHttpResponse response;
    try {
      response = await _sendAuthenticated(
        method: method,
        url: url,
        body: body,
        idempotencyKey: idempotencyKey,
      );
    } on UqpayTransportException catch (e) {
      _logger.log('$method ${url.path} -> transport failure: ${e.kind.name}');
      return UqpayApiFailure<UqpayPaymentIntent>(
        mapFailure(transportFailure: e.kind),
      );
    } on _TokenProviderFailure catch (e) {
      _logger.log('$method ${url.path} -> tokenProvider ${e.reason}');
      return UqpayApiFailure<UqpayPaymentIntent>(
        UqpayError(
          code: UqpayErrorCode.authenticationFailed,
          developerMessage:
              'The tokenProvider failed to supply an auth token: ${e.reason}',
          userMessage: defaultUserMessage(UqpayErrorCode.authenticationFailed),
          isRetryable: false,
        ),
      );
    } on Exception {
      // Any other `Exception` escaping the HTTP client (a platform stack
      // quirk, a merchant-supplied client's own exception type) is a
      // transport fault: reported with a FIXED message — never the
      // exception's text, which on some stacks echoes headers — and as
      // outcome unknown for anything that may have reached the server.
      // `Error`s (programming bugs) are deliberately NOT caught here: the
      // flow reports them to FlutterError as SDK bugs.
      _logger.log(
        '$method ${url.path} -> unexpected exception from the client',
      );
      return UqpayApiFailure<UqpayPaymentIntent>(
        UqpayError(
          code: UqpayErrorCode.networkError,
          developerMessage:
              'The HTTP client threw an unexpected exception before a '
              'response was received.',
          userMessage: defaultUserMessage(UqpayErrorCode.networkError),
          isRetryable: true,
          isOutcomeUnknown: method != 'GET',
        ),
      );
    }

    _logger.http(
      method: method,
      url: url,
      status: response.statusCode,
      traceId: response.traceId,
    );
    if (!response.isSuccess) {
      final envelope = _decodeEnvelope(response.body);
      _logger.log(
        '$method ${url.path} failed'
        '${envelope?.code == null ? '' : ' code=${envelope!.code}'}',
      );
      return UqpayApiFailure<UqpayPaymentIntent>(
        mapFailure(
          httpStatus: response.statusCode,
          envelopeCode: envelope?.code,
          envelopeType: envelope?.type,
          envelopeMessage: envelope == null
              ? _boundedRawBody(response.body)
              : envelope.message,
          traceId: response.traceId,
          responseId: response.responseId,
        ),
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('body is not a JSON object');
      }
      return UqpayApiSuccess<UqpayPaymentIntent>(
        UqpayPaymentIntent.fromJson(decoded),
        traceId: response.traceId,
        responseId: response.responseId,
      );
    } on FormatException {
      return UqpayApiFailure<UqpayPaymentIntent>(
        mapFailure(
          malformedResponse: true,
          httpStatus: response.statusCode,
          traceId: response.traceId,
          responseId: response.responseId,
        ),
      );
    }
  }

  /// Sends once; on 401 invalidates the token and sends exactly once more.
  Future<UqpayHttpResponse> _sendAuthenticated({
    required String method,
    required Uri url,
    String? body,
    String? idempotencyKey,
  }) async {
    var response = await _sendWithToken(
      method: method,
      url: url,
      body: body,
      idempotencyKey: idempotencyKey,
    );
    if (response.statusCode == 401) {
      _logger.log('$method ${url.path} -> 401; refreshing the token once');
      _tokens.invalidate();
      response = await _sendWithToken(
        method: method,
        url: url,
        body: body,
        idempotencyKey: idempotencyKey,
      );
    }
    return response;
  }

  Future<UqpayHttpResponse> _sendWithToken({
    required String method,
    required Uri url,
    String? body,
    String? idempotencyKey,
  }) async {
    final String token;
    try {
      token = (await _tokens.token()).value.trim();
    } on TimeoutException {
      throw const _TokenProviderFailure('timed out');
    } catch (e) {
      // Never let a merchant callback's exception escape as a crash.
      throw _TokenProviderFailure(e is Error ? 'error' : 'exception');
    }
    if (token.isEmpty || !_headerSafe.hasMatch(token)) {
      // A token with a newline or a non-ASCII byte would make the HTTP
      // stack throw a FormatException whose text contains the token itself
      // — straight into crash reporting. Refuse it here, by class.
      throw const _TokenProviderFailure(
        'returned a token that is empty or not a valid header value',
      );
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'x-auth-token': 'Bearer $token',
      if (body != null) 'content-type': 'application/json',
      'x-idempotency-key': ?idempotencyKey,
      'x-client-id': ?_sdk.clientId,
      'x-on-behalf-of': ?_sdk.onBehalfOf,
    };
    return _httpClient.send(
      UqpayHttpRequest(
        method: method,
        url: url,
        headers: headers,
        timeout: requestTimeout,
        body: body,
      ),
    );
  }

  /// Decodes the error envelope tolerantly: every field
  /// defaults to absent; returns `null` when the body is not a JSON object.
  static _ErrorEnvelope? _decodeEnvelope(String body) {
    if (body.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final r = JsonReader(decoded);
      return _ErrorEnvelope(
        code: r.optionalString('code', emptyAsNull: true),
        type: r.optionalString('type', emptyAsNull: true),
        message: r.optionalString('message', emptyAsNull: true),
      );
    } on FormatException {
      return null;
    }
  }

  /// A non-JSON error body (a proxy's HTML page, plain text), bounded to 300
  /// chars on one line, for the developer message. Any run of 12+ digits is
  /// masked first so an echoing proxy can never leak a PAN into a log.
  static String? _boundedRawBody(String body) {
    final oneLine = redactCardLikeDigits(
      body.replaceAll(RegExp(r'\s+'), ' '),
    ).trim();
    if (oneLine.isEmpty) {
      return null;
    }
    return oneLine.length <= 300 ? oneLine : '${oneLine.substring(0, 300)}…';
  }
}

class _ErrorEnvelope {
  const _ErrorEnvelope({this.code, this.type, this.message});
  final String? code;
  final String? type;
  final String? message;
}

/// Visible ASCII only: what an HTTP header value may safely carry.
final RegExp _headerSafe = RegExp(r'^[\x21-\x7E]+$');

class _TokenProviderFailure implements Exception {
  const _TokenProviderFailure(this.reason);
  final String reason;
}
