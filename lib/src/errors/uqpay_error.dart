import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';

/// A failure the SDK reports to the merchant.
///
/// Errors are **returned, never thrown** for expected outcomes; the
/// only things the SDK throws are [ArgumentError]/[StateError] for programmer
/// error at configuration time. Every error carries:
///
/// * [code] — a stable typed code to branch on;
/// * [developerMessage] — what happened, for logs and support tickets;
/// * [userMessage] — safe to show to the customer as-is: no jargon, no JSON,
///   no server codes, and it says what to do next;
/// * [isRetryable] — whether the *same* request may be sent again;
/// * [isOutcomeUnknown] — whether the server may have processed the payment
///   despite the failure (money-safety: never report such an error as a
///   decline; reconcile instead);
/// * [traceId] / [responseId] — the API's `x-trace-id` / `x-response-id`
///   headers when present, to quote to UQPAY support;
/// * [httpStatus], [serverCode], [serverMessage] — the raw facts, verbatim.
///
/// [toString] includes no card data and no user-entered text: it prints the
/// code, the HTTP status and the trace id only.
@immutable
class UqpayError {
  /// Creates an error. Prefer the SDK's single mapper over constructing
  /// errors by hand.
  const UqpayError({
    required this.code,
    required this.developerMessage,
    required this.userMessage,
    required this.isRetryable,
    this.isOutcomeUnknown = false,
    this.httpStatus,
    this.serverCode,
    this.serverMessage,
    this.traceId,
    this.responseId,
  });

  /// The typed code.
  final UqpayErrorCode code;

  /// Developer-facing description. May contain the server's message and the
  /// HTTP status. Never contains card data.
  final String developerMessage;

  /// Customer-facing message, safe to display verbatim.
  final String userMessage;

  /// Whether the same request may safely be retried (with the same
  /// idempotency key for mutating calls).
  final bool isRetryable;

  /// Whether the server may have processed the request. When `true` the
  /// caller must reconcile the intent's status rather than treat the payment
  /// as failed.
  final bool isOutcomeUnknown;

  /// The HTTP status of the response that produced this error, if any.
  final int? httpStatus;

  /// The server's machine code verbatim (error-envelope `code` or attempt
  /// `failure_code`), if any.
  final String? serverCode;

  /// The server's human-readable message verbatim, if any. May be empty.
  final String? serverMessage;

  /// The API's `x-trace-id` response header, if present.
  final String? traceId;

  /// The API's `x-response-id` response header, if present.
  final String? responseId;

  /// Convenience for [UqpayErrorCode.isUnknown] on [code].
  bool get isUnknown => code.isUnknown;

  /// Returns a copy with the given fields replaced. Used by the transport to
  /// stamp trace ids onto errors built lower down.
  UqpayError copyWith({
    int? httpStatus,
    String? traceId,
    String? responseId,
    bool? isRetryable,
    bool? isOutcomeUnknown,
  }) => UqpayError(
    code: code,
    developerMessage: developerMessage,
    userMessage: userMessage,
    isRetryable: isRetryable ?? this.isRetryable,
    isOutcomeUnknown: isOutcomeUnknown ?? this.isOutcomeUnknown,
    httpStatus: httpStatus ?? this.httpStatus,
    serverCode: serverCode,
    serverMessage: serverMessage,
    traceId: traceId ?? this.traceId,
    responseId: responseId ?? this.responseId,
  );

  @override
  bool operator ==(Object other) =>
      other is UqpayError &&
      other.code == code &&
      other.developerMessage == developerMessage &&
      other.userMessage == userMessage &&
      other.isRetryable == isRetryable &&
      other.isOutcomeUnknown == isOutcomeUnknown &&
      other.httpStatus == httpStatus &&
      other.serverCode == serverCode &&
      other.serverMessage == serverMessage &&
      other.traceId == traceId &&
      other.responseId == responseId;

  @override
  int get hashCode => Object.hash(
    code,
    developerMessage,
    userMessage,
    isRetryable,
    isOutcomeUnknown,
    httpStatus,
    serverCode,
    serverMessage,
    traceId,
    responseId,
  );

  @override
  String toString() =>
      'UqpayError(code: ${code.raw}, httpStatus: $httpStatus, '
      'retryable: $isRetryable, outcomeUnknown: $isOutcomeUnknown, '
      'traceId: $traceId)';
}
