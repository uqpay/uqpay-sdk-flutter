import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_customer.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_intent_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_next_action.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_attempt.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_method.dart';
import 'package:uqpay_sdk_flutter/src/money/uqpay_amount.dart';

/// A payment intent — the one object the API returns from create, retrieve
/// and confirm.
///
/// This is the **union** of the two decodings the iOS SDK carries
/// (explicit keys ∪ snake_case-converted), with exactly two required
/// fields — [id] and [status] — and everything else nullable, because the
/// server may legitimately omit any of them on some responses. Keys
/// are explicit snake_case.
///
/// Amounts are exact [UqpayAmount]s in major units; the SDK never scales
/// them. [toString] prints only the id and status.
class UqpayPaymentIntent extends UqpayJsonModel {
  /// Creates an intent. Only [id] and [status] are required.
  const UqpayPaymentIntent({
    required this.id,
    required this.status,
    this.amount,
    this.currency,
    this.capturedAmount,
    this.paymentMethod,
    this.customer,
    this.customerId,
    this.cancelTime,
    this.cancellationReason,
    this.clientSecret,
    this.merchantOrderId,
    this.description,
    this.metadata,
    this.nextAction,
    this.returnUrl,
    this.createTime,
    this.updateTime,
    this.completeTime,
    this.latestPaymentAttempt,
    this.availablePaymentMethodTypes,
  });

  /// Decodes an intent object.
  ///
  /// Throws [FormatException] only when `payment_intent_id` or
  /// `intent_status` is missing; every other field is lenient. An
  /// unrecognised status decodes to an unknown [UqpayIntentStatus] rather
  /// than throwing.
  factory UqpayPaymentIntent.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final paymentMethod = r.optionalObject('payment_method');
    final customer = r.optionalObject('customer');
    final nextAction = r.optionalObject('next_action');
    final attempt = r.optionalObject('latest_payment_attempt');
    return UqpayPaymentIntent(
      id: r.requireString('payment_intent_id'),
      status: UqpayIntentStatus.fromRaw(r.requireString('intent_status')),
      amount: r.optionalAmount('amount'),
      currency: r.optionalString('currency', emptyAsNull: true),
      capturedAmount: r.optionalAmount('captured_amount'),
      // A payment_method without a `type` is malformed; drop it rather than
      // fail the whole intent.
      paymentMethod:
          paymentMethod == null ||
              paymentMethod['type'] is! String ||
              (paymentMethod['type']! as String).trim().isEmpty
          ? null
          : UqpayPaymentMethod.fromJson(paymentMethod),
      customer: customer == null ? null : UqpayCustomer.fromJson(customer),
      customerId: r.optionalString('customer_id', emptyAsNull: true),
      cancelTime: r.optionalString('cancel_time', emptyAsNull: true),
      cancellationReason: r.optionalString(
        'cancellation_reason',
        emptyAsNull: true,
      ),
      clientSecret: r.optionalString('client_secret', emptyAsNull: true),
      merchantOrderId: r.optionalString('merchant_order_id', emptyAsNull: true),
      description: r.optionalString('description'),
      metadata: r.optionalStringMap('metadata'),
      nextAction: nextAction == null
          ? null
          : UqpayNextAction.fromJson(nextAction),
      returnUrl: r.optionalString('return_url', emptyAsNull: true),
      createTime: r.optionalString('create_time', emptyAsNull: true),
      updateTime: r.optionalString('update_time', emptyAsNull: true),
      completeTime: r.optionalString('complete_time', emptyAsNull: true),
      latestPaymentAttempt: attempt == null
          ? null
          : UqpayPaymentAttempt.fromJson(attempt),
      availablePaymentMethodTypes: r.optionalStringList(
        'available_payment_method_types',
      ),
    );
  }

  /// Intent id (`payment_intent_id`), e.g. `pi_…`.
  final String id;

  /// Lifecycle status (`intent_status`).
  final UqpayIntentStatus status;

  /// Amount to charge, in major units.
  final UqpayAmount? amount;

  /// ISO 4217 currency, e.g. `SGD`.
  final String? currency;

  /// Amount captured so far, in major units.
  final UqpayAmount? capturedAmount;

  /// The payment method attached by confirm.
  final UqpayPaymentMethod? paymentMethod;

  /// The customer.
  final UqpayCustomer? customer;

  /// Customer id.
  final String? customerId;

  /// Cancellation timestamp string.
  final String? cancelTime;

  /// Cancellation reason.
  final String? cancellationReason;

  /// The intent's client secret. Nullable: a server omitting it must not
  /// brick a status read.
  final String? clientSecret;

  /// The merchant's order id.
  final String? merchantOrderId;

  /// Free-form description.
  final String? description;

  /// Free-form string→string metadata.
  final Map<String, String>? metadata;

  /// The action the customer must take, when [status] requires one.
  final UqpayNextAction? nextAction;

  /// The merchant's return URL, echoed from create.
  final String? returnUrl;

  /// Creation timestamp string.
  final String? createTime;

  /// Last-update timestamp string.
  final String? updateTime;

  /// Completion timestamp string.
  final String? completeTime;

  /// The most recent attempt.
  final UqpayPaymentAttempt? latestPaymentAttempt;

  /// Method-type strings this intent can be paid with — the source of a
  /// payment sheet's method list. `null` when the server did not send it.
  final List<String>? availablePaymentMethodTypes;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'payment_intent_id': id,
    'intent_status': status.raw,
    'amount': amount?.toWireString(),
    'currency': currency,
    'captured_amount': capturedAmount?.toWireString(),
    'payment_method': paymentMethod?.toJson(),
    'customer': customer?.toJson(),
    'customer_id': customerId,
    'cancel_time': cancelTime,
    'cancellation_reason': cancellationReason,
    'client_secret': clientSecret,
    'merchant_order_id': merchantOrderId,
    'description': description,
    'metadata': metadata,
    'next_action': nextAction?.toJson(),
    'return_url': returnUrl,
    'create_time': createTime,
    'update_time': updateTime,
    'complete_time': completeTime,
    'latest_payment_attempt': latestPaymentAttempt?.toJson(),
    'available_payment_method_types': availablePaymentMethodTypes,
  });

  @override
  String toString() => 'UqpayPaymentIntent(id: $id, status: ${status.raw})';
}
