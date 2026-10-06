import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_logger.dart';
import 'package:uqpay_sdk_flutter/src/core/uuid.dart';
import 'package:uqpay_sdk_flutter/src/flow/intent_outcome.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_cancel_reason.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_intent_result.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payment_flow.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payment_result.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_confirm_request.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_intent_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_presenter.dart';
import 'package:uqpay_sdk_flutter/src/transport/http_package_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_api_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/src/uqpay_environment.dart';
import 'package:uqpay_sdk_flutter/src/uqpay_sdk.dart';

/// The headless payment API — everything the drop-in sheet can do, as typed
/// calls. Obtain it from [UqpaySdk.payments].
///
/// Every method that talks to the server **returns** its outcome — a
/// [UqpayPaymentResult] or [UqpayIntentResult] — and never throws for a
/// decline, a cancel, a timeout, a 4xx or a 5xx. The only exceptions
/// are [ArgumentError]s for programmer error at call time (empty intent id,
/// missing `tokenProvider`, a flow created without a request).
///
/// ```dart
/// final uqpay = UqpaySdk.init(environment: …, tokenProvider: …);
///
/// // Simplest: one call, one result.
/// final result = await uqpay.payments.confirm(intentId, request);
///
/// // With progress, cancel and lifecycle control:
/// final flow = uqpay.payments.createFlow(intentId: id, request: request);
/// flow.status.listen(showProgress);
/// final result = await flow.confirm();
/// ```
///
/// **On launch**, call [reconcileUnresolved] (or look at
/// [unresolvedIntentIds]) so a payment interrupted by process death is
/// resolved against the server before your app offers a new attempt.
class UqpayPayments {
  /// Creates a payments API over explicit dependencies. Production code uses
  /// [UqpaySdk.payments]; tests inject fakes here.
  ///
  /// Throws [ArgumentError] naming `tokenProvider` when [sdk] has none —
  /// before any request is built.
  @visibleForTesting
  UqpayPayments.withDependencies({
    required this.sdk,
    required UqpayHttpClient httpClient,
    required UqpayClock clock,
    required KeyValueStore storage,
    PollingPolicy? pollingPolicy,
    Future<String?> Function()? deviceIpResolver,
  }) : _httpClient = httpClient,
       _deviceIpResolver = deviceIpResolver,
       _clock = clock,
       _policy = pollingPolicy ?? PollingPolicy(),
       _logger = UqpayLogger(
         enabled: sdk.loggingEnabled,
         handler: sdk.logHandler,
       ),
       _api = UqpayApiClient(
         sdk: sdk,
         httpClient: httpClient,
         clock: clock,
         logger: UqpayLogger(
           enabled: sdk.loggingEnabled,
           handler: sdk.logHandler,
         ),
       ),
       _store = IdempotencyStore(
         storage: storage,
         clock: clock,
         namespace: IdempotencyStore.namespaceFor(
           environment: switch (sdk.environment) {
             UqpayEnvironment.sandbox => 'sandbox',
             UqpayEnvironment.production => 'production',
           },
           baseUrl: sdk.baseUrl,
           merchant: sdk.clientId,
         ),
       );

  /// Creates the production payments API for [sdk]: real HTTP, real clock,
  /// `shared_preferences` for idempotency pins. Performs no I/O until the
  /// first call.
  factory UqpayPayments.forSdk(UqpaySdk sdk) {
    final clock = SystemUqpayClock();
    return UqpayPayments.withDependencies(
      sdk: sdk,
      httpClient: HttpPackageClient(),
      clock: clock,
      // Bounded so a wedged platform channel can never hang a payment:
      // a storage call that overruns 5 s fails instead.
      storage: BoundedKeyValueStore(
        SharedPreferencesKeyValueStore(),
        clock: clock,
      ),
    );
  }

  /// Supplies the device IP for `ip_address`; `null` uses the platform
  /// resolver. Tests inject a deterministic one.
  final Future<String?> Function()? _deviceIpResolver;

  /// The default outcome deadline for [confirm] / [createFlow]: 5 minutes of
  /// active waiting, the iOS 3-D Secure budget. QR
  /// flows should pass 10 minutes.
  static const Duration defaultOutcomeDeadline = Duration(minutes: 5);

  /// The `cancellation_reason` sent by [cancelIntent] when none is given.
  static const String defaultCancellationReason = 'requested_by_customer';

  /// The SDK handle this API belongs to.
  final UqpaySdk sdk;

  final UqpayHttpClient _httpClient;
  final UqpayClock _clock;
  final PollingPolicy _policy;
  final UqpayLogger _logger;
  final UqpayApiClient _api;
  final IdempotencyStore _store;

  /// Reads an intent from the server (`GET /api/v2/payment_intents/{id}`).
  ///
  /// Use it to build your own checkout screen: the amount, currency and
  /// `availablePaymentMethodTypes` come from here. Throws [ArgumentError]
  /// only for an empty [intentId].
  Future<UqpayIntentResult> retrieveIntent(String intentId) async {
    if (intentId.trim().isEmpty) {
      throw ArgumentError.value(intentId, 'intentId', 'must not be empty');
    }
    return switch (await _api.retrievePaymentIntent(intentId)) {
      UqpayApiSuccess<UqpayPaymentIntent>(:final value) => UqpayIntentRetrieved(
        value,
      ),
      UqpayApiFailure<UqpayPaymentIntent>(:final error) =>
        UqpayIntentUnavailable(error),
    };
  }

  /// Creates a [UqpayPaymentFlow] for [intentId] without starting it.
  ///
  /// Pass [request] to be able to call [UqpayPaymentFlow.confirm]; leave it
  /// `null` for a flow that only [UqpayPaymentFlow.awaitOutcome]s.
  /// [outcomeDeadline] bounds the *active* waiting for an outcome (paused and
  /// suspended time excluded); default [defaultOutcomeDeadline].
  ///
  /// Pass [challengePresenter] to have a 3-D Secure / redirect challenge
  /// presented automatically: when the server serves a `redirect_to_url` or
  /// `redirect_iframe` action, the flow presents it **once** and then keeps
  /// polling — the server's status, never the presenter's outcome, decides
  /// the result. With `null` (the default) the flow only surfaces
  /// the action on [UqpayPaymentFlow.status] and merchants present it
  /// themselves.
  UqpayPaymentFlow createFlow({
    required String intentId,
    UqpayConfirmRequest? request,
    Duration outcomeDeadline = defaultOutcomeDeadline,
    UqpayChallengePresenter? challengePresenter,
  }) {
    if (outcomeDeadline <= Duration.zero) {
      throw ArgumentError.value(
        outcomeDeadline,
        'outcomeDeadline',
        'must be positive',
      );
    }
    final flow = UqpayPaymentFlow.internal(
      api: _api,
      store: _store,
      clock: _clock,
      policy: _policy.withBudget(outcomeDeadline),
      reconciler: reconcile,
      intentId: intentId,
      request: request,
      challengePresenter: challengePresenter,
      deviceIpResolver: _deviceIpResolver,
      logger: _logger,
    );
    _purgeExpiredOnce();
    // Remembered so a startup reconcile cannot read an intent this process
    // is still paying and release its live pin.
    _inFlight.add(intentId);
    unawaited(flow.result.whenComplete(() => _inFlight.remove(intentId)));
    return flow;
  }

  /// Intents with a flow created by this instance whose result is not yet
  /// delivered.
  final Set<String> _inFlight = <String>{};

  bool _purgeStarted = false;

  /// Removes pins older than 24 h once per instance, in the background, so
  /// pins nobody reconciles do not accumulate in `shared_preferences`.
  /// Errors are swallowed: housekeeping never affects a payment.
  void _purgeExpiredOnce() {
    if (_purgeStarted) {
      return;
    }
    _purgeStarted = true;
    unawaited(_purgeExpiredSilently());
  }

  Future<void> _purgeExpiredSilently() async {
    try {
      await _store.purgeExpired();
    } on Object {
      // Best effort.
    }
  }

  /// Confirms [intentId] with [request] and waits for the outcome — the
  /// one-call form of [createFlow] + [UqpayPaymentFlow.confirm].
  ///
  /// Reads the intent first and returns immediately, without confirming, if
  /// it is already terminal or authorised. Persists an idempotency
  /// key before sending, replays a lost response with the same key, and polls
  /// for the outcome (3-D Secure, QR) until [outcomeDeadline] of active
  /// waiting has passed. Never throws for a payment outcome.
  Future<UqpayPaymentResult> confirm(
    String intentId,
    UqpayConfirmRequest request, {
    Duration outcomeDeadline = defaultOutcomeDeadline,
  }) => createFlow(
    intentId: intentId,
    request: request,
    outcomeDeadline: outcomeDeadline,
  ).confirm();

  /// Waits for the outcome of an intent that was already confirmed — after
  /// a redirect, a QR scan, or a `UqpayPaymentPending` result — polling with
  /// back-off until it resolves or [deadline] of active waiting has passed.
  /// Sends no confirm. Never throws for a payment outcome.
  Future<UqpayPaymentResult> awaitOutcome(
    String intentId, {
    Duration deadline = defaultOutcomeDeadline,
  }) => createFlow(
    intentId: intentId,
    outcomeDeadline: deadline,
  ).awaitOutcome();

  /// Reads [intentId] from the server **once** and maps it to a result: a
  /// terminal or authorised intent yields [UqpayPaymentCompleted] /
  /// [UqpayPaymentFailed] / [UqpayPaymentCanceled]; anything still in flight
  /// (or a read that failed) yields [UqpayPaymentPending] with the reason in
  /// `cause`. Idempotency pins for a resolved intent are released. Never
  /// throws for a payment outcome.
  Future<UqpayPaymentResult> reconcile(String intentId) async {
    _purgeExpiredOnce();
    switch (await _api.retrievePaymentIntent(intentId)) {
      case UqpayApiSuccess<UqpayPaymentIntent>(
        :final value,
        :final traceId,
        :final responseId,
      ):
        // A reconcile does not know whether a confirm ever left, so the
        // server's own evidence decides: with an attempt attached, that
        // attempt is classified (a decline is a decline); with none,
        // REQUIRES_PAYMENT_METHOD is "payable" and reported as Pending —
        // never as the decline of a confirm that may not exist (a crash
        // between pinning and sending).
        switch (IntentOutcome.of(
          value,
          afterConfirm: value.latestPaymentAttempt != null,
          traceId: traceId,
          responseId: responseId,
        )) {
          case Resolved(:final result):
            await _releasePinsFor(intentId, keepIfRetryable: result);
            return result;
          case Payable():
          case KeepWaiting():
            return UqpayPaymentPending(
              intentId: intentId,
              lastKnownStatus: value.status,
              intent: value,
              reconcile: () => reconcile(intentId),
            );
        }
      case UqpayApiFailure<UqpayPaymentIntent>(:final error):
        return UqpayPaymentPending(
          intentId: intentId,
          lastKnownStatus: null,
          cause: error,
          reconcile: () => reconcile(intentId),
        );
    }
  }

  /// Cancels [intentId] on the server
  /// (`POST /api/v2/payment_intents/{id}/cancel`).
  ///
  /// [cancellationReason] is sent verbatim; the API documents `duplicate`,
  /// `fraudulent`, `requested_by_customer` and `abandoned`. On success the
  /// result is [UqpayPaymentCanceled] with
  /// [UqpayCancelReason.merchantCancelled]; if the server refuses (for
  /// example the intent already succeeded) the result is
  /// [UqpayPaymentFailed] carrying the server's error — reconcile to learn
  /// the intent's real state. Cancels are never auto-retried.
  ///
  /// This is a **server** cancel of the intent. To call off a payment flow
  /// running in this app use [UqpayPaymentFlow.cancel], which sends nothing.
  Future<UqpayPaymentResult> cancelIntent(
    String intentId, {
    String cancellationReason = defaultCancellationReason,
  }) async {
    final response = await _api.cancelPaymentIntent(
      id: intentId,
      cancellationReason: cancellationReason,
      idempotencyKey: generateUuidV4(),
    );
    switch (response) {
      case UqpayApiSuccess<UqpayPaymentIntent>(:final value):
        // Observed against the gateway: the cancel endpoint answers 2xx with
        // the intent's PREVIOUS status and `cancellation_reason` already set;
        // the status flips to CANCELLED a few seconds later. An accepted cancel
        // is a cancel — never a decline of a confirm that was never sent.
        final accepted =
            value.status.isCancelled ||
            (value.cancellationReason != null &&
                !value.status.isSuccess &&
                value.status != UqpayIntentStatus.failed);
        if (accepted) {
          await _releasePinsFor(intentId);
          return UqpayPaymentCanceled(
            intentId: intentId,
            reason: UqpayCancelReason.merchantCancelled,
            intent: value,
          );
        }
        // 2xx with a settled (paid / failed) intent: report what it is.
        return switch (IntentOutcome.of(value, afterConfirm: false)) {
          Resolved(:final result) => result,
          Payable() || KeepWaiting() => UqpayPaymentPending(
            intentId: intentId,
            lastKnownStatus: value.status,
            intent: value,
            reconcile: () => reconcile(intentId),
          ),
        };
      case UqpayApiFailure<UqpayPaymentIntent>(:final error):
        return UqpayPaymentFailed(intentId: intentId, error: error);
    }
  }

  /// The ids of intents that have an unexpired idempotency pin in this
  /// environment — payments whose confirm was sent (or about to be sent) and
  /// never resolved in this app, typically because the process died.
  /// Call [reconcile] or [reconcileUnresolved] on them before
  /// offering the customer a new attempt.
  Future<List<String>> unresolvedIntentIds() async {
    final pins = await _store.unresolved();
    final ids = <String>{for (final pin in pins) pin.intentId};
    return List<String>.unmodifiable(ids);
  }

  /// [reconcile]s every intent in [unresolvedIntentIds] and returns the
  /// results in the same order. Pins of resolved intents are released;
  /// unresolved ones stay until their 24 h expiry.
  Future<List<UqpayPaymentResult>> reconcileUnresolved() async {
    final results = <UqpayPaymentResult>[];
    final List<String> ids;
    try {
      ids = await unresolvedIntentIds();
    } on Object {
      // Storage unavailable: nothing can be listed, nothing is lost — the
      // pins are still there for the next launch.
      return const <UqpayPaymentResult>[];
    }
    for (final id in ids) {
      if (_inFlight.contains(id)) {
        // This process is still paying it; its own flow will deliver.
        continue;
      }
      try {
        results.add(await reconcile(id));
      } on Object {
        // One intent must not abort the sweep; it stays pinned for later.
        results.add(
          UqpayPaymentPending(
            intentId: id,
            lastKnownStatus: null,
            reconcile: () => reconcile(id),
          ),
        );
      }
    }
    return List<UqpayPaymentResult>.unmodifiable(results);
  }

  /// Releases the underlying HTTP connections. Idempotent. A closed instance
  /// must not be used again; create a new [UqpaySdk] handle instead.
  void close() => _httpClient.close();

  Future<void> _releasePinsFor(
    String intentId, {
    UqpayPaymentResult? keepIfRetryable,
  }) async {
    if (keepIfRetryable case UqpayPaymentFailed(
      :final error,
    ) when error.isRetryable || error.isOutcomeUnknown) {
      return;
    }
    try {
      for (final pin in await _store.unresolved()) {
        if (pin.intentId == intentId) {
          await _store.release(
            intentId: intentId,
            fingerprint: pin.fingerprint,
          );
        }
      }
    } on Object {
      // Best effort: a pin that could not be released expires in 24 h.
      // Never let a storage error surface as a payment error.
    }
  }
}
