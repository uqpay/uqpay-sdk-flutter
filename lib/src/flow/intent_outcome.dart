import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_cancel_reason.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payment_result.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_attempt_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_intent_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';

/// Classifies an intent as the server returned it (from confirm, GET or
/// cancel) into "what the flow should do next".
///
/// This is the **one** place an intent object becomes a result, for every
/// payment method (the error inside a [Resolved] failure always comes from
/// `mapFailure`). Rules, per the gateway's documented status rules:
///
/// * `SUCCEEDED` or `REQUIRES_CAPTURE` → completed (never "failed").
/// * `CANCELLED` / `CANCELED` → canceled with
///   [UqpayCancelReason.intentCancelled].
/// * `FAILED` → failed, mapped from the latest attempt's `failure_code`.
/// * `REQUIRES_PAYMENT_METHOD` **after** a confirm or during polling → the
///   attempt failed (decline / 3DS abandoned) when an attempt exists, or
///   nothing was attached when none does. **Before** a confirm it means the
///   intent is payable — the caller decides which context applies via
///   `afterConfirm`.
/// * anything else (`REQUIRES_CUSTOMER_ACTION`, `PENDING`, `PROCESSING`,
///   unknown) → keep waiting.
sealed class IntentOutcome {
  const IntentOutcome();

  /// Classifies [intent]. `afterConfirm` is `true` when a confirm has been
  /// sent for this attempt (so `REQUIRES_PAYMENT_METHOD` means "failed").
  /// `lostConfirmError` is the error of a confirm whose outcome was unknown
  /// (timeout, 5xx, undecodable 2xx): when the server then shows **no**
  /// attempt at all, the confirm evidently never landed and *that* error is
  /// the honest result — retryable, same idempotency key.
  factory IntentOutcome.of(
    UqpayPaymentIntent intent, {
    required bool afterConfirm,
    UqpayError? lostConfirmError,
    String? attemptIdBeforeConfirm,
    String? traceId,
    String? responseId,
  }) {
    final status = intent.status;
    if (status.isSuccess) {
      return Resolved(UqpayPaymentCompleted(intent: intent));
    }
    if (status.isCancelled) {
      return Resolved(
        UqpayPaymentCanceled(
          intentId: intent.id,
          reason: UqpayCancelReason.intentCancelled,
          intent: intent,
        ),
      );
    }
    final attempt = intent.latestPaymentAttempt;
    if (status == UqpayIntentStatus.failed) {
      return Resolved(
        UqpayPaymentFailed(
          intentId: intent.id,
          intent: intent,
          error: mapFailure(
            intentStatus: status,
            attemptFailed: true,
            attemptFailureCode: attempt?.failureCode,
            attemptFailureMessage: attempt?.failureMessage,
            traceId: traceId,
            responseId: responseId,
          ),
        ),
      );
    }
    if (status == UqpayIntentStatus.requiresPaymentMethod) {
      if (!afterConfirm) {
        return const Payable();
      }
      if (attempt != null) {
        final attemptStatus = attempt.status;
        final isStale =
            attemptIdBeforeConfirm != null &&
            attempt.attemptId != null &&
            attempt.attemptId == attemptIdBeforeConfirm;
        if (lostConfirmError != null &&
            (isStale ||
                attempt.attemptId == null ||
                attemptIdBeforeConfirm == null)) {
          // With a confirm whose outcome is unknown, an attempt that cannot
          // be proven to be OURS (same id as before, or ids unavailable) is
          // not evidence of a decline. Keep polling; the budget resolves
          // Pending.
          return const KeepWaiting();
        }
        if (isStale && lostConfirmError != null) {
          // The only attempt visible predates our confirm, whose outcome is
          // unknown: ours may still be materialising. Keep polling; the
          // budget turns this into Pending, never into the OLD attempt's
          // decline.
          return const KeepWaiting();
        }
        final settled =
            attemptStatus == UqpayAttemptStatus.failed ||
            attemptStatus == UqpayAttemptStatus.expired ||
            attemptStatus == UqpayAttemptStatus.cancelled ||
            attempt.failureCode != null;
        if (!settled) {
          // INITIATED, PENDING_AUTHORIZATION, an unknown status: an attempt
          // is in progress. Not a decline.
          return const KeepWaiting();
        }
        if (isStale) {
          // A settled attempt that predates ours, and our confirm was
          // answered definitively: nothing new is attached.
          return Resolved(
            UqpayPaymentFailed(
              intentId: intent.id,
              intent: intent,
              error: mapFailure(
                intentStatus: status,
                noPaymentMethodAttached: true,
                traceId: traceId,
                responseId: responseId,
              ),
            ),
          );
        }
      }
      final attemptFailed = attempt != null;
      return Resolved(
        UqpayPaymentFailed(
          intentId: intent.id,
          intent: intent,
          error: attemptFailed
              ? mapFailure(
                  intentStatus: status,
                  attemptFailed: true,
                  attemptFailureCode: attempt.failureCode,
                  attemptFailureMessage: attempt.failureMessage,
                  traceId: traceId,
                  responseId: responseId,
                )
              : lostConfirmError ??
                    mapFailure(
                      intentStatus: status,
                      noPaymentMethodAttached: true,
                      traceId: traceId,
                      responseId: responseId,
                    ),
        ),
      );
    }
    if (status == UqpayIntentStatus.requiresCustomerAction &&
        intent.nextAction == null &&
        attempt != null &&
        (attempt.status == UqpayAttemptStatus.failed ||
            attempt.status == UqpayAttemptStatus.expired ||
            attempt.status == UqpayAttemptStatus.cancelled ||
            attempt.failureCode != null)) {
      // Observed against the gateway: it can leave the intent in
      // REQUIRES_CUSTOMER_ACTION with the attempt definitively FAILED and no
      // further action. Nothing is pending for the customer: this is a
      // failure of THIS attempt, reported with its own code, not a 5-minute
      // wait ending in Pending.
      return Resolved(
        UqpayPaymentFailed(
          intentId: intent.id,
          intent: intent,
          error: mapFailure(
            intentStatus: status,
            attemptFailed: true,
            attemptFailureCode: attempt.failureCode,
            attemptFailureMessage: attempt.failureMessage,
            traceId: traceId,
            responseId: responseId,
          ),
        ),
      );
    }
    return const KeepWaiting();
  }
}

/// The intent has a final answer.
final class Resolved extends IntentOutcome {
  /// Creates a resolved outcome.
  const Resolved(this.result);

  /// The result to deliver.
  final UqpayPaymentResult result;
}

/// `REQUIRES_PAYMENT_METHOD` before any confirm: the intent can be paid.
final class Payable extends IntentOutcome {
  /// Creates a payable outcome.
  const Payable();
}

/// Non-terminal: keep polling (and surface `next_action` if present).
final class KeepWaiting extends IntentOutcome {
  /// Creates a keep-waiting outcome.
  const KeepWaiting();
}
