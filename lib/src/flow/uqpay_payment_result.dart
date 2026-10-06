import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_cancel_reason.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_intent_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_attempt.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';

/// How a payment ended, as seen from the app.
///
/// A Dart 3 **sealed** class with exactly four cases —
/// [UqpayPaymentCompleted], [UqpayPaymentFailed], [UqpayPaymentCanceled] and
/// [UqpayPaymentPending] — so a `switch` over it is exhaustive with no
/// `default`. **This set is frozen for the whole 1.x line**: adding a case
/// would break every merchant's switch, so nuances live inside the cases
/// (an open [UqpayError.code], an open [UqpayCancelReason], the intent's open
/// status) rather than as new cases.
///
/// Every payment operation in the SDK **returns** one of these — never
/// throws — for declines, cancels, timeouts, 4xx and 5xx alike.
/// Exceptions are reserved for programmer error at call time.
///
/// ```dart
/// switch (await uqpay.payments.confirm(intentId, request)) {
///   case UqpayPaymentCompleted(:final intent):
///     // show the receipt — and let your server confirm by webhook
///   case UqpayPaymentFailed(:final error):
///     // show error.userMessage; offer a retry if error.isRetryable
///   case UqpayPaymentCanceled(:final reason):
///     // the customer or your code backed out; nothing was charged
///   case UqpayPaymentPending(:final intentId):
///     // the outcome is not known yet — reconcile later or await your webhook
/// }
/// ```
///
/// **The client result is a UX signal, not proof of payment.** Fulfilment
/// must be driven by your server from UQPAY's webhook or a server-side status
/// check.
@immutable
sealed class UqpayPaymentResult {
  const UqpayPaymentResult();

  /// The intent this result is about.
  String get intentId;

  /// The last intent object the SDK read from the server, if any.
  UqpayPaymentIntent? get intent;
}

/// The customer has paid: the intent is `SUCCEEDED` **or**
/// `REQUIRES_CAPTURE` (authorised; your side captures or auto-capture
/// settles it).
final class UqpayPaymentCompleted extends UqpayPaymentResult {
  /// Creates a completed result.
  const UqpayPaymentCompleted({required UqpayPaymentIntent intent})
    : _intent = intent;

  final UqpayPaymentIntent _intent;

  /// The intent as last read from the server. Never `null` for a completed
  /// payment.
  @override
  UqpayPaymentIntent get intent => _intent;

  @override
  String get intentId => _intent.id;

  /// The intent's status at completion: `SUCCEEDED` or `REQUIRES_CAPTURE`.
  UqpayIntentStatus get status => _intent.status;

  /// The attempt that succeeded, when the server included it.
  UqpayPaymentAttempt? get attempt => _intent.latestPaymentAttempt;

  @override
  String toString() =>
      'UqpayPaymentCompleted(intentId: $intentId, status: ${status.raw})';
}

/// The payment definitively did not go through: a decline, a rejected
/// request, an authentication failure, or a transport failure before the
/// request reached the server.
///
/// [error] says which, in a stable typed [UqpayError.code], with a
/// user-safe message. When `error.isRetryable` is `true` the same request may
/// be sent again — the SDK reuses the same idempotency key.
final class UqpayPaymentFailed extends UqpayPaymentResult {
  /// Creates a failed result.
  const UqpayPaymentFailed({
    required this.intentId,
    required this.error,
    this.intent,
  });

  @override
  final String intentId;

  /// What went wrong.
  final UqpayError error;

  /// The intent as last read, if the SDK managed to read it.
  @override
  final UqpayPaymentIntent? intent;

  @override
  String toString() =>
      'UqpayPaymentFailed(intentId: $intentId, code: ${error.code.raw})';
}

/// The payment was called off before any charge could happen.
///
/// [reason] distinguishes who: the customer dismissing the UI, the customer
/// tapping Cancel, the merchant's code, or the server having already
/// cancelled the intent. A cancel requested **while a confirm was in
/// flight** is *not* reported as canceled — it is a [UqpayPaymentPending],
/// because the server may still take the payment.
final class UqpayPaymentCanceled extends UqpayPaymentResult {
  /// Creates a canceled result.
  const UqpayPaymentCanceled({
    required this.intentId,
    required this.reason,
    this.intent,
  });

  @override
  final String intentId;

  /// Who or what cancelled.
  final UqpayCancelReason reason;

  /// The intent as last read, if any.
  @override
  final UqpayPaymentIntent? intent;

  @override
  String toString() =>
      'UqpayPaymentCanceled(intentId: $intentId, reason: ${reason.raw})';
}

/// The outcome is not known yet.
///
/// Produced when the outcome deadline passed while the intent was still in
/// flight, when a confirm's response was lost and the replays could not
/// settle it, or when the flow was cancelled mid-confirm. Nothing here means
/// the payment failed — it may well succeed. Your server's webhook is the
/// authoritative answer; from the app, call [reconcile] later, or start
/// `UqpayPayments.awaitOutcome` to poll again.
final class UqpayPaymentPending extends UqpayPaymentResult {
  /// Creates a pending result. [reconcile] is what
  /// [UqpayPaymentPending.reconcile] calls.
  const UqpayPaymentPending({
    required this.intentId,
    required this.lastKnownStatus,
    required Future<UqpayPaymentResult> Function() reconcile,
    this.intent,
    this.cause,
  }) : _reconcile = reconcile;

  @override
  final String intentId;

  /// The intent status the SDK last saw, or `null` when it never managed to
  /// read the intent.
  final UqpayIntentStatus? lastKnownStatus;

  /// The intent as last read, if any.
  @override
  final UqpayPaymentIntent? intent;

  /// Why the SDK stopped waiting, when a specific error caused it (deadline
  /// exceeded, response lost, poll failure). `null` for a cancel-mid-confirm.
  final UqpayError? cause;

  final Future<UqpayPaymentResult> Function() _reconcile;

  /// Reads the intent from the server **once** and maps it to a result: a
  /// terminal or authorised intent gives [UqpayPaymentCompleted] /
  /// [UqpayPaymentFailed] / [UqpayPaymentCanceled]; an intent still in flight
  /// gives another [UqpayPaymentPending]. Never throws.
  Future<UqpayPaymentResult> reconcile() => _reconcile();

  @override
  String toString() =>
      'UqpayPaymentPending(intentId: $intentId, '
      'lastKnownStatus: ${lastKnownStatus?.raw})';
}
