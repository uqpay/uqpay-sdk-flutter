import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_attempt_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_authentication_data.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';
import 'package:uqpay_sdk_flutter/src/money/uqpay_amount.dart';

/// One attempt to pay an intent (`latest_payment_attempt`).
///
/// Decoding is **fully lenient**: every field is optional and a wrong-typed
/// value reads as absent, so a bookkeeping change on the server can never make
/// a 2xx confirm response undecodable and strand an answered payment. Empty
/// `failure_code` / `failure_message` strings — which the API commonly sends
/// instead of omitting the field — are normalised to `null`.
///
/// Amounts are exact [UqpayAmount]s (number-as-string on the wire).
class UqpayPaymentAttempt extends UqpayJsonModel {
  /// Creates an attempt.
  const UqpayPaymentAttempt({
    this.attemptId,
    this.paymentIntentId,
    this.status,
    this.amount,
    this.currency,
    this.capturedAmount,
    this.refundedAmount,
    this.authCode,
    this.arn,
    this.rrn,
    this.adviceCode,
    this.failureCode,
    this.failureMessage,
    this.authenticationData,
    this.createTime,
    this.updateTime,
    this.completeTime,
    this.cancelTime,
    this.cancellationReason,
  });

  /// Decodes an attempt object. Never throws.
  ///
  /// Accepts the id under `attempt_id` (nested under an intent) **or**
  /// `payment_attempt_id` (webhook payloads).
  factory UqpayPaymentAttempt.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final status = r.optionalString('attempt_status', emptyAsNull: true);
    final authentication = r.optionalObject('authentication_data');
    return UqpayPaymentAttempt(
      attemptId:
          r.optionalString('attempt_id', emptyAsNull: true) ??
          r.optionalString('payment_attempt_id', emptyAsNull: true),
      paymentIntentId: r.optionalString('payment_intent_id', emptyAsNull: true),
      status: status == null ? null : UqpayAttemptStatus.fromRaw(status),
      amount: r.optionalAmount('amount'),
      currency: r.optionalString('currency', emptyAsNull: true),
      capturedAmount: r.optionalAmount('captured_amount'),
      refundedAmount: r.optionalAmount('refunded_amount'),
      authCode: r.optionalString('auth_code', emptyAsNull: true),
      arn: r.optionalString('arn', emptyAsNull: true),
      rrn: r.optionalString('rrn', emptyAsNull: true),
      adviceCode: r.optionalString('advice_code', emptyAsNull: true),
      failureCode: r.optionalString('failure_code', emptyAsNull: true),
      failureMessage: r.optionalString('failure_message', emptyAsNull: true),
      authenticationData: authentication == null
          ? null
          : UqpayAuthenticationData.fromJson(authentication),
      createTime: r.optionalString('create_time', emptyAsNull: true),
      updateTime: r.optionalString('update_time', emptyAsNull: true),
      completeTime: r.optionalString('complete_time', emptyAsNull: true),
      cancelTime: r.optionalString('cancel_time', emptyAsNull: true),
      cancellationReason: r.optionalString(
        'cancellation_reason',
        emptyAsNull: true,
      ),
    );
  }

  /// Attempt id (`attempt_id`, or `payment_attempt_id` in webhooks).
  final String? attemptId;

  /// Parent intent id.
  final String? paymentIntentId;

  /// Attempt status.
  final UqpayAttemptStatus? status;

  /// Attempt amount in major units.
  final UqpayAmount? amount;

  /// ISO 4217 currency.
  final String? currency;

  /// Captured amount in major units.
  final UqpayAmount? capturedAmount;

  /// Refunded amount in major units.
  final UqpayAmount? refundedAmount;

  /// Issuer authorisation code.
  final String? authCode;

  /// Acquirer reference number.
  final String? arn;

  /// Retrieval reference number.
  final String? rrn;

  /// Advice code.
  final String? adviceCode;

  /// Machine-readable failure code, e.g. `3ds_failed`, `insufficient_funds`.
  /// `null` when absent or empty.
  final String? failureCode;

  /// Human-readable failure reason. Often absent on the confirm response and
  /// present on a later intent GET.
  final String? failureMessage;

  /// CVV / AVS / 3-D Secure results.
  final UqpayAuthenticationData? authenticationData;

  /// Creation timestamp string.
  final String? createTime;

  /// Last-update timestamp string.
  final String? updateTime;

  /// Completion timestamp string.
  final String? completeTime;

  /// Cancellation timestamp string.
  final String? cancelTime;

  /// Cancellation reason.
  final String? cancellationReason;

  /// Whether this attempt is a decline: status `FAILED`.
  bool get isFailed => status == UqpayAttemptStatus.failed;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'attempt_id': attemptId,
    'payment_intent_id': paymentIntentId,
    'attempt_status': status?.raw,
    'amount': amount?.toWireString(),
    'currency': currency,
    'captured_amount': capturedAmount?.toWireString(),
    'refunded_amount': refundedAmount?.toWireString(),
    'auth_code': authCode,
    'arn': arn,
    'rrn': rrn,
    'advice_code': adviceCode,
    'failure_code': failureCode,
    'failure_message': failureMessage,
    'authentication_data': authenticationData?.toJson(),
    'create_time': createTime,
    'update_time': updateTime,
    'complete_time': completeTime,
    'cancel_time': cancelTime,
    'cancellation_reason': cancellationReason,
  });

  @override
  String toString() =>
      'UqpayPaymentAttempt(id: $attemptId, status: ${status?.raw}, '
      'failureCode: $failureCode)';
}
