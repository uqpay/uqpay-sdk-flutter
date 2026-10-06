import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_logger.dart';
import 'package:uqpay_sdk_flutter/src/device/device_ip.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/flow/intent_outcome.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_cancel_reason.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payment_result.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payment_status.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_confirm_request.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_intent_status.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_next_action.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_presenter.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_api_client.dart';

/// One payment attempt on one intent, from "nothing sent yet" to exactly one
/// [UqpayPaymentResult].
///
/// Create one with `UqpayPayments.createFlow`, then either [confirm] (send
/// the confirm request and wait for the outcome) or [awaitOutcome] (only
/// wait — for an intent whose confirm already happened, for example after a
/// 3-D Secure redirect or a QR scan). Both are idempotent: calling either a
/// second time returns the same future and sends nothing more.
///
/// ```dart
/// final flow = uqpay.payments.createFlow(intentId: id, request: request);
/// flow.status.listen((s) => debugPrint('${s.phase}'));
/// final result = await flow.confirm();
/// ```
///
/// ### States
///
/// ```text
/// idle ──confirm()/awaitOutcome()──▶ preparing (GET intent, terminal guard)
///   │                                   │ terminal / authorised ─▶ done
///   │                                   │ payable ─▶ confirming
///   │                                   │ in flight ─▶ awaiting
///   │                                   ▼
///   │                              confirming (POST confirm; replay 3/6/10 s
///   │                                   │  on outcome-unknown, same key+bytes)
///   │                                   │ definitive answer ─▶ done
///   │                                   ▼
///   │                              awaiting (poll with back-off; pause/resume)
///   │                                   │ terminal / decline ─▶ done
///   │                                   │ budget exhausted ─▶ done (Pending)
///   ▼                                   ▼
/// cancel() before anything was sent ─▶ done (Canceled)
/// cancel() after the confirm left    ─▶ done (Pending)
/// ```
///
/// Every path ends in `done` exactly once; [result] can never stay
/// unresolved. After `done` the [status] stream is closed and no timer or
/// subscription is left behind.
///
/// ### What "cancel" means
///
/// [cancel] before the confirm request has left the device produces
/// [UqpayPaymentCanceled] with your reason. [cancel] *after* it has left —
/// while the SDK is waiting for the response, replaying it, or polling for
/// the outcome — produces [UqpayPaymentPending], because the server may still
/// take the payment; use `UqpayPaymentPending.reconcile` (or your webhook) to
/// learn what happened.
///
/// ### Lifecycle
///
/// A UI layer should call [pause] when the app goes to the background and
/// [resume] when it returns. While paused nothing is sent; on resume the flow
/// polls the server **immediately, once**, before settling back into its
/// back-off schedule. Time spent paused or suspended never counts
/// against the outcome deadline.
class UqpayPaymentFlow {
  /// Creates a flow over explicit internals. **Not for merchant use** —
  /// call `UqpayPayments.createFlow`, which wires the SDK's transport, clock
  /// and idempotency store. Exists for the payments facade and for tests.
  @internal
  UqpayPaymentFlow.internal({
    required UqpayApiClient api,
    required IdempotencyStore store,
    required UqpayClock clock,
    required PollingPolicy policy,
    required Future<UqpayPaymentResult> Function(String intentId) reconciler,
    required this.intentId,
    this.request,
    UqpayChallengePresenter? challengePresenter,
    Future<String?> Function()? deviceIpResolver,
    UqpayLogger logger = UqpayLogger.disabled,
  }) : _api = api,
       _logger = logger,
       _deviceIpResolver = deviceIpResolver ?? resolveDeviceIpAddress,
       _store = store,
       _clock = clock,
       _policy = policy,
       _reconciler = reconciler,
       _challengePresenter = challengePresenter {
    if (intentId.trim().isEmpty) {
      throw ArgumentError.value(intentId, 'intentId', 'must not be empty');
    }
  }

  /// The replay ladder for a confirm whose outcome is unknown
  /// (the gateway's documented retry schedule): waits before the 2nd, 3rd and
  /// 4th send.
  static const List<Duration> replayLadder = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 10),
  ];

  final UqpayApiClient _api;
  final UqpayLogger _logger;
  final IdempotencyStore _store;
  final UqpayClock _clock;
  final PollingPolicy _policy;
  final Future<UqpayPaymentResult> Function(String intentId) _reconciler;
  final UqpayChallengePresenter? _challengePresenter;

  /// Supplies the device's own IP for `ip_address`. Injected so widget tests
  /// — which run in a fake-async zone where real interface enumeration never
  /// completes — can answer without touching the platform (the injected-clock
  /// rule, applied to I/O rather than to time).
  final Future<String?> Function() _deviceIpResolver;

  /// Challenge fingerprints already handed to the presenter, so the same
  /// `next_action` re-served across polls is presented exactly once.
  final Set<String> _presentedChallenges = <String>{};

  /// Completed to tell the presenter to close the challenge currently on
  /// screen: on [_finish], or when the presentation outlives its bound.
  Completer<void>? _challengeCancel;

  /// The intent this flow pays.
  final String intentId;

  /// The confirm body, or `null` for a flow that only awaits an outcome.
  final UqpayConfirmRequest? request;

  final Completer<UqpayPaymentResult> _completer =
      Completer<UqpayPaymentResult>();
  final StreamController<UqpayPaymentStatus> _statusController =
      StreamController<UqpayPaymentStatus>.broadcast();

  _Stage _stage = _Stage.idle;
  bool _confirmSent = false;

  /// Whether the terminal-intent guard read failed (fail-open). While true,
  /// a definitive-looking rejection of the confirm cannot be trusted as the
  /// final word: the intent may already have succeeded.
  bool _guardFailed = false;

  /// `latest_payment_attempt.attempt_id` as seen before this flow's confirm,
  /// so a poll that still shows that attempt is known to predate ours.
  String? _attemptIdBeforeConfirm;

  /// How many challenges this flow has presented; capped so a server that
  /// rotates the challenge URL cannot drive an unbounded present/read loop.
  int _presentations = 0;

  /// The most presentations one flow will make (the gateway's documented
  /// behaviour is that the server re-serves the same action; anything beyond
  /// this is a loop).
  static const int maxPresentations = 3;
  bool _paused = false;
  UqpayDelay? _activeDelay;
  Completer<void>? _resumeGate;
  UqpayPaymentIntent? _latest;
  IdempotencyPin? _pin;
  int _pollCount = 0;
  Duration _budgetUsed = Duration.zero;
  UqpayError? _lostConfirmError;
  UqpayError? _lastPollError;

  /// The result, delivered exactly once. Never completes with an error.
  Future<UqpayPaymentResult> get result => _completer.future;

  /// Progress events, closed as soon as [result] is delivered.
  ///
  /// A broadcast stream: subscribe before or after starting, from as many
  /// places as you like. If a listener throws, the error is reported through
  /// `FlutterError.onError` and the flow carries on unaffected.
  Stream<UqpayPaymentStatus> get status =>
      _GuardedStream<UqpayPaymentStatus>(_statusController.stream);

  /// Whether this flow minted the idempotency pin it holds. A pin inherited
  /// from an earlier attempt (a retry) is never released by a flow that did
  /// not create it: the earlier send may still be live on the server.
  bool _ownsPin = false;

  /// Whether [confirm] or [awaitOutcome] has been called.
  bool get hasStarted => _stage != _Stage.idle;

  /// Whether the confirm request has left the device (after this, [cancel]
  /// yields [UqpayPaymentPending] rather than [UqpayPaymentCanceled]).
  bool get isConfirmInFlight => _confirmSent && !isDone;

  /// Whether [result] has been delivered.
  bool get isDone => _stage == _Stage.done;

  /// Whether the flow is paused (see [pause]).
  bool get isPaused => _paused;

  /// The intent as last read from the server, if any.
  UqpayPaymentIntent? get latestIntent => _latest;

  /// Sends the confirm request for [request] and waits for the outcome.
  ///
  /// Idempotent: a second call returns the same [result] and sends nothing
  /// (double-tap safety at the API level). Throws [ArgumentError] naming
  /// `request` when the flow was created without one — that is the only
  /// exception it can throw; every payment outcome is returned.
  Future<UqpayPaymentResult> confirm() {
    if (_stage == _Stage.idle) {
      if (request == null) {
        throw ArgumentError.value(
          null,
          'request',
          'createFlow was called without a confirm request; use awaitOutcome '
              'to wait for an intent confirmed elsewhere',
        );
      }
      _start(doConfirm: true);
    }
    return result;
  }

  /// Fills in `ip_address` from the device when the caller left it unset.
  ///
  /// The gateway rejects a card confirm that carries no `ip_address`
  /// (observed against the sandbox: `invalid_payment_method — ip
  /// address is invalid`), and a merchant driving the headless API has no
  /// way to obtain an interface address on their own. Resolving it here, on
  /// the one path every confirm takes, means the sheet and the headless API
  /// get it alike.
  ///
  /// It happens **before** the idempotency pin is written, so the pinned body
  /// is the body that is sent and a replay stays byte-identical. A
  /// caller who supplied an address keeps it; a device that has none sends
  /// no field rather than an invented one.
  /// Resolves the device IP, bounded on the SDK clock so a hung interface
  /// enumeration cannot outlive the outcome deadline.
  Future<String?> _resolveIpBounded() async {
    final bound = _clock.startDelay(const Duration(seconds: 5));
    try {
      return await Future.any<String?>([
        _deviceIpResolver(),
        bound.future.then((_) => null),
      ]);
    } on Object {
      return null;
    } finally {
      bound.cancel();
    }
  }

  static UqpayConfirmRequest _withIpAddress(
    UqpayConfirmRequest original,
    String? ipAddress,
  ) {
    if (ipAddress == null || original.ipAddress == ipAddress) {
      return original;
    }
    return UqpayConfirmRequest(
      paymentMethod: original.paymentMethod,
      browserInfo: original.browserInfo,
      ipAddress: ipAddress,
    );
  }

  /// Waits for the outcome of an intent whose confirm already happened —
  /// polls until it is terminal, authorised, declined, or the outcome
  /// deadline passes. Sends **no** confirm. Idempotent.
  Future<UqpayPaymentResult> awaitOutcome() {
    if (_stage == _Stage.idle) {
      _start(doConfirm: false);
    }
    return result;
  }

  /// Calls the payment off.
  ///
  /// Before the confirm request has left the device the result is
  /// [UqpayPaymentCanceled] with [reason]. Once it has left — response
  /// pending, replaying, or polling for the outcome — the result is
  /// [UqpayPaymentPending], never [UqpayPaymentCanceled]: the server may still
  /// take the payment. A flow started with [awaitOutcome] watches a payment
  /// that is already in flight, so cancelling it after it started likewise
  /// yields [UqpayPaymentPending]. After [result] is delivered this is a
  /// no-op.
  void cancel(UqpayCancelReason reason) {
    if (isDone) {
      return;
    }
    // A flow that only awaits an outcome watches a payment already in flight
    // on the server, so once started it can only end Pending — there is
    // nothing local left to call off.
    final beforePointOfNoReturn =
        !_confirmSent && (request != null || !hasStarted);
    if (beforePointOfNoReturn) {
      unawaited(
        _finish(
          UqpayPaymentCanceled(
            intentId: intentId,
            reason: reason,
            intent: _latest,
          ),
        ),
      );
      return;
    }
    // Past the point of no return the result is Pending whatever the reason;
    // a QR that expired on screen is named as the cause so the merchant can
    // tell it from a customer closing the sheet.
    final cause = reason.raw == 'qr_expired'
        ? UqpayError(
            code: UqpayErrorCode.timeout,
            developerMessage:
                'The QR code expired before the server reported an outcome. '
                'Reconcile before offering a new attempt: a last-second scan '
                'may still have settled.',
            userMessage: defaultUserMessage(UqpayErrorCode.timeout),
            isRetryable: true,
            isOutcomeUnknown: true,
          )
        : null;
    unawaited(_finish(_pending(cause: cause)));
  }

  /// Suspends network activity (call when the app goes to the background).
  ///
  /// A request already in flight completes; nothing new is sent until
  /// [resume]. Paused time never counts against the outcome deadline.
  void pause() {
    if (isDone || _paused) {
      return;
    }
    _paused = true;
    _resumeGate = Completer<void>();
    if (_stage == _Stage.awaiting) {
      _emit(UqpayPaymentPhase.paused);
    }
  }

  /// Ends a [pause]. The flow reads the intent from the server **immediately,
  /// once**, then continues its back-off schedule.
  void resume() {
    if (!_paused) {
      return;
    }
    _paused = false;
    if (_stage == _Stage.awaiting) {
      // The last event was `paused`; headless UIs need the resumed phase.
      _emitAwaiting();
    }
    // Wake a wait in progress so the next poll happens now.
    _activeDelay?.cancel();
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  // ---- internals ----------------------------------------------------------

  void _start({required bool doConfirm}) {
    _stage = _Stage.preparing;
    unawaited(_run(doConfirm: doConfirm));
  }

  Future<void> _run({required bool doConfirm}) async {
    try {
      await _prepareAndMaybeConfirm(doConfirm: doConfirm);
    } on Object catch (error, stackTrace) {
      // A bug inside the SDK must still resolve the merchant's future
      // — and must not be swallowed.
      //
      // Resolution comes FIRST and reporting second, deliberately. Reporting
      // is diagnostics; resolving the merchant's future is the contract. If
      // those two are ever in conflict, the contract wins.
      //
      // Once a confirm has left the device the server may have taken the
      // payment, so an unexpected throw resolves Pending (pin kept, outcome
      // unknown) — never a Failed that invites a second charge.
      await _finish(
        _confirmSent
            ? _pending(cause: mapFailure())
            : UqpayPaymentFailed(
                intentId: intentId,
                intent: _latest,
                error: mapFailure(),
              ),
      );
      _reportSdkError(error, stackTrace, 'while running a payment flow');
    }
  }

  Future<void> _prepareAndMaybeConfirm({required bool doConfirm}) async {
    // 1. Terminal-intent guard: read before sending anything.
    _emit(UqpayPaymentPhase.preparing);
    final guard = await _api.retrievePaymentIntent(intentId);
    if (isDone) {
      return;
    }
    var proceedToConfirm = doConfirm;
    switch (guard) {
      case UqpayApiSuccess<UqpayPaymentIntent>(
        :final value,
        :final traceId,
        :final responseId,
      ):
        _latest = value;
        _attemptIdBeforeConfirm = value.latestPaymentAttempt?.attemptId;
        switch (IntentOutcome.of(
          value,
          afterConfirm: !doConfirm,
          traceId: traceId,
          responseId: responseId,
        )) {
          case Resolved(:final result):
            // Terminal (or authorised) already: never send a confirm.
            await _finish(result);
            return;
          case Payable():
            proceedToConfirm = true;
          case KeepWaiting():
            // Something is already in flight for this intent (a QR issued,
            // a 3DS challenge pending, settlement pending). Re-serve it
            // rather than confirm a second time, unless
            // the status is unknown or an action-less REQUIRES_CUSTOMER_ACTION
            // (fail open).
            final s = value.status;
            // Observed against the gateway: a no-3DS card sits a few seconds in
            // REQUIRES_CUSTOMER_ACTION with no action and an
            // AUTHENTICATION_REDIRECTED attempt before SUCCEEDED. A confirm
            // sent then creates a SECOND attempt. Only fall open when the
            // server shows no attempt at all.
            proceedToConfirm =
                doConfirm &&
                (s.isUnknown ||
                    (s == UqpayIntentStatus.requiresCustomerAction &&
                        value.nextAction == null &&
                        value.latestPaymentAttempt == null));
        }
      case UqpayApiFailure<UqpayPaymentIntent>():
        // Fail open: the confirm (or the poll loop) will produce the real
        // answer; a transport blip on the guard must not block a payment.
        // Remembered, because without a guard read a rejected confirm may
        // mean "already paid" rather than "declined".
        _guardFailed = true;
    }

    if (proceedToConfirm) {
      final done = await _confirm();
      if (done) {
        return;
      }
    }
    await _pollUntilResolved();
  }

  /// Sends the confirm with the persisted idempotency key, replaying on an
  /// unknown outcome. Returns `true` when the flow finished here.
  Future<bool> _confirm() async {
    final original = request!;
    final resolvedIp = original.ipAddress ?? await _resolveIpBounded();
    if (isDone) {
      return true;
    }
    if (resolvedIp == null && original.paymentMethod.card != null) {
      // The gateway rejects every card confirm without an ip_address
      // (observed: `400 invalid_payment_method "ip address is
      // invalid"`), and reports it as a card problem. Fail before sending,
      // naming the real cause, instead of telling the customer their card
      // was refused.
      await _finish(
        UqpayPaymentFailed(
          intentId: intentId,
          intent: _latest,
          error: UqpayError(
            code: UqpayErrorCode.invalidConfiguration,
            developerMessage:
                'No device IP address could be determined and the gateway '
                'requires ip_address on a card confirm. Supply '
                'UqpayConfirmRequest.ipAddress yourself (on web, from your '
                'server) or retry on a device with a network interface.',
            userMessage: defaultUserMessage(UqpayErrorCode.networkError),
            isRetryable: true,
          ),
        ),
      );
      return true;
    }
    _stage = _Stage.confirming;

    // The key is minted once per logical attempt and durably stored
    // BEFORE the request leaves the device. The fingerprint excludes the
    // SDK-resolved device IP and the pin remembers it instead, so a retry
    // from a different network reuses the same key AND the same bytes
    // (a caller-supplied ipAddress stays part of the
    // body and the fingerprint, as the caller intended).
    final IdempotencyPin pin;
    try {
      final obtained = await _store.obtainOrReuse(
        intentId: intentId,
        body: original.toJson(),
        ipAddress: original.ipAddress == null ? resolvedIp : null,
      );
      pin = obtained.pin;
      _ownsPin = obtained.created;
    } on Object catch (error, stackTrace) {
      // Storage refused the pin: nothing was sent, so this is a retryable
      // local failure, not a decline and not an SDK crash.
      await _finish(
        UqpayPaymentFailed(
          intentId: intentId,
          intent: _latest,
          error: UqpayError(
            code: UqpayErrorCode.unknown,
            developerMessage:
                'The idempotency pin could not be written to local storage '
                '(it failed or did not respond within 5 s); nothing was sent.',
            userMessage: defaultUserMessage(UqpayErrorCode.unknown),
            isRetryable: true,
          ),
        ),
      );
      _reportSdkError(error, stackTrace, 'while writing an idempotency pin');
      return true;
    }
    _pin = pin;
    // A reused pin replays EXACTLY the bytes of the first send: its IP when
    // the SDK resolved one then, and no IP at all when it did not.
    final body = original.ipAddress != null
        ? original
        : _withIpAddress(original, _ownsPin ? resolvedIp : pin.ipAddress);
    if (isDone) {
      // Cancelled while the pin was being written: nothing was sent, so the
      // pin has nothing to protect.
      await _releasePin();
      return true;
    }
    _emit(UqpayPaymentPhase.confirming);

    var replay = 0;
    while (true) {
      if (_paused) {
        // Nothing is sent while paused — a replay included.
        await _resumeGate?.future;
        if (isDone) {
          return true;
        }
      }
      _confirmSent = true;
      final response = await _api.confirmPaymentIntent(
        id: intentId,
        request: body,
        idempotencyKey: pin.key,
      );
      if (isDone) {
        // Cancelled mid-flight (result already Pending). Still tidy the pin
        // if the late answer turned out to be definitive.
        if (response case UqpayApiSuccess<UqpayPaymentIntent>(:final value)) {
          _latest = value;
          if (IntentOutcome.of(value, afterConfirm: true) is Resolved) {
            await _releasePin(definitive: true);
          }
        }
        return true;
      }
      switch (response) {
        case UqpayApiSuccess<UqpayPaymentIntent>(
          :final value,
          :final traceId,
          :final responseId,
        ):
          _latest = value;
          switch (IntentOutcome.of(
            value,
            afterConfirm: true,
            traceId: traceId,
            responseId: responseId,
          )) {
            case Resolved(:final result):
              await _finish(result);
              return true;
            case Payable():
            case KeepWaiting():
              return false;
          }
        case UqpayApiFailure<UqpayPaymentIntent>(:final error):
          final neverLeft =
              replay == 0 &&
              error.code == UqpayErrorCode.authenticationFailed &&
              error.httpStatus == null;
          if (neverLeft) {
            // The tokenProvider failed before the first send: no request
            // ever left the device, so this is an honest Failed (retryable
            // once the merchant's backend answers again), not Pending.
            _confirmSent = false;
            await _finish(
              UqpayPaymentFailed(
                intentId: intentId,
                intent: _latest,
                error: error,
              ),
            );
            return true;
          }
          if (!error.isOutcomeUnknown && (replay > 0 || _guardFailed)) {
            // A definitive-looking answer to a REPLAY (or to a confirm sent
            // without a successful guard read) cannot be the final word: an
            // earlier send may already have charged the card, and the
            // rejection may be "intent not payable" because it did. Let the
            // poll loop read the server's truth.
            _lostConfirmError = error;
            return false;
          }
          if (!error.isOutcomeUnknown) {
            // A definitive rejection of the first and only send, with the
            // intent known payable a moment ago: decline, invalid request,
            // auth.
            await _finish(
              UqpayPaymentFailed(
                intentId: intentId,
                intent: _latest,
                error: error,
              ),
            );
            return true;
          }
          if (error.isRetryable && replay < replayLadder.length) {
            // Replay the same key + same bytes.
            _emit(UqpayPaymentPhase.retrying);
            await _wait(replayLadder[replay]);
            replay++;
            if (isDone) {
              return true;
            }
            continue;
          }
          // Ladder exhausted, or a 2xx we could not decode: the server may
          // have processed it — reconcile by polling.
          _lostConfirmError = error;
          return false;
      }
    }
  }

  /// Polls the intent with back-off until it resolves or the budget is spent.
  Future<void> _pollUntilResolved() async {
    _stage = _Stage.awaiting;
    _emitAwaiting();
    var pollIndex = 0;
    var consecutiveFailures = 0;
    while (true) {
      // A redirect challenge the server (re-)serves is handed to
      // the presenter here — once per distinct challenge — and on ANY
      // outcome the next read happens immediately: the outcome is a signal,
      // the server's status is the answer. Time spent inside the challenge
      // consumes none of the poll budget.
      final presented = await _maybePresentChallenge();
      if (isDone) {
        return;
      }
      final wait = presented ? Duration.zero : _policy.waitBefore(pollIndex);
      if (_budgetUsed + wait > _policy.budget) {
        await _finish(
          _pending(
            cause: consecutiveFailures > 0
                ? _lastPollError
                : mapFailure(outcomeDeadlineExceeded: true),
          ),
        );
        return;
      }
      if (wait > Duration.zero) {
        // Charge the time that actually passed, capped at the scheduled
        // wait: a resume() that cuts the wait short must not spend the full
        // interval, and a suspension that overshoots it must not spend
        // more than was scheduled (suspended time never counts).
        final before = _clock.elapsed;
        await _wait(wait);
        final spent = _clock.elapsed - before;
        _budgetUsed += spent < Duration.zero
            ? Duration.zero
            : (spent > wait ? wait : spent);
      }
      if (isDone) {
        return;
      }
      if (_paused) {
        await _resumeGate?.future;
        if (isDone) {
          return;
        }
      }

      _pollCount++;
      final read = await _api.retrievePaymentIntent(intentId);
      if (isDone) {
        return;
      }
      switch (read) {
        case UqpayApiSuccess<UqpayPaymentIntent>(
          :final value,
          :final traceId,
          :final responseId,
        ):
          consecutiveFailures = 0;
          final changed =
              _latest?.status != value.status ||
              _latest?.nextAction != value.nextAction;
          _latest = value;
          switch (IntentOutcome.of(
            value,
            afterConfirm: true,
            lostConfirmError: _lostConfirmError,
            attemptIdBeforeConfirm: _attemptIdBeforeConfirm,
            traceId: traceId,
            responseId: responseId,
          )) {
            case Resolved(:final result):
              await _finish(result);
              return;
            case Payable():
            case KeepWaiting():
              if (changed) {
                _emitAwaiting();
              }
          }
        case UqpayApiFailure<UqpayPaymentIntent>(:final error):
          consecutiveFailures++;
          _lastPollError = error;
          if (error.code == UqpayErrorCode.authenticationFailed) {
            // The token was rejected after a refresh; polling cannot help.
            await _finish(_pending(cause: error));
            return;
          }
      }
      pollIndex++;
    }
  }

  /// Hands a redirect `next_action` to the challenge presenter, if one was
  /// supplied and this exact challenge has not been presented yet. Returns
  /// `true` when a presentation happened (so the caller re-reads the intent
  /// immediately). Presenter outcomes and exceptions never resolve the flow
  /// by themselves — the server's status does.
  Future<bool> _maybePresentChallenge() async {
    final presenter = _challengePresenter;
    final intent = _latest;
    if (presenter == null || intent == null || _paused) {
      return false;
    }
    if (intent.status != UqpayIntentStatus.requiresCustomerAction) {
      return false;
    }
    final action = intent.nextAction;
    if (action == null) {
      return false;
    }
    final type = action.type;
    String? fingerprint;
    if (type == UqpayNextActionType.redirectToUrl) {
      final url = action.redirectToUrl?.url;
      if (url == null || url.isEmpty) {
        return false;
      }
      fingerprint = 'url:$url';
    } else if (type == UqpayNextActionType.redirectIframe) {
      final iframe = action.redirectIframe?.iframe;
      if (iframe == null || iframe.isEmpty) {
        return false;
      }
      fingerprint = 'iframe:$iframe';
    } else {
      // QR / bank details / unknown actions are surfaced on [status] only.
      return false;
    }
    if (!_presentedChallenges.add(fingerprint)) {
      return false;
    }
    if (_presentations >= maxPresentations) {
      // A server rotating the challenge on every read would otherwise drive
      // an unbounded present/read loop with no budget spent. Beyond the
      // cap the flow simply polls; a late outcome is still caught.
      return false;
    }
    _presentations++;
    final rawReturnUrl = action.redirectToUrl?.returnUrl ?? intent.returnUrl;
    final returnUrl = rawReturnUrl == null ? null : Uri.tryParse(rawReturnUrl);
    final cancel = Completer<void>();
    _challengeCancel = cancel;
    try {
      // The outcome is deliberately unused beyond "the presentation ended":
      // returned, dismissed, failed and timed out all lead to the same next
      // step — one immediate read of the server's status.
      await _presentBounded(
        presenter,
        UqpayChallengeRequest(
          intentId: intentId,
          action: action,
          // With no return_url anywhere, a sentinel that matches no http(s)
          // navigation: app-scheme returns still end the browser step.
          returnUrl: returnUrl ?? Uri(scheme: 'uqpay-return', host: 'none'),
          cancelled: cancel.future,
        ),
        cancel,
      );
    } on Object catch (error, stackTrace) {
      // A presenter must not throw; treat a throw as "presentation failed"
      // and reconcile anyway (report, never break the flow).
      _reportSdkError(
        error,
        stackTrace,
        'while a UqpayChallengePresenter presented a challenge',
      );
    } finally {
      if (identical(_challengeCancel, cancel)) {
        _challengeCancel = null;
      }
    }
    return true;
  }

  /// How long one presentation may stay open, in active (unpaused) time,
  /// before the flow closes it and reads the server anyway: twice the
  /// presenter's own [UqpayChallengeRequest.timeout]. The SDK's webview
  /// presenter times out first; this only bounds a presenter that never
  /// completes.
  static Duration _presentationBound(Duration challengeTimeout) =>
      challengeTimeout * 2;

  /// Awaits [presenter] for [request], bounded on the SDK clock (so
  /// tests drive it). A bound that expires while the flow is paused waits
  /// for [resume] and re-arms in full (suspended time never counts).
  /// On expiry the presenter is told to close via [cancel] and the
  /// flow moves on without it. [_finish] completes [cancel] too, which also
  /// ends this wait.
  Future<void> _presentBounded(
    UqpayChallengePresenter presenter,
    UqpayChallengeRequest request,
    Completer<void> cancel,
  ) async {
    final presentation = presenter.present(request);
    while (true) {
      final bound = _clock.startDelay(_presentationBound(request.timeout));
      final boundExpired = await Future.any<bool>([
        presentation.then((_) => false),
        cancel.future.then((_) => false),
        bound.future.then((_) => true),
      ]).whenComplete(bound.cancel);
      if (!boundExpired || isDone) {
        return;
      }
      if (_paused) {
        await _resumeGate?.future;
        if (isDone) {
          return;
        }
        continue;
      }
      _logger.log(
        'flow $intentId: challenge presentation exceeded its bound; closing',
      );
      if (!cancel.isCompleted) {
        cancel.complete();
      }
      return;
    }
  }

  Future<void> _wait(Duration duration) async {
    final delay = _clock.startDelay(duration);
    _activeDelay = delay;
    await delay.future;
    if (identical(_activeDelay, delay)) {
      _activeDelay = null;
    }
  }

  UqpayPaymentPending _pending({UqpayError? cause}) => UqpayPaymentPending(
    intentId: intentId,
    lastKnownStatus: _latest?.status,
    intent: _latest,
    cause: cause,
    reconcile: () => _reconciler(intentId),
  );

  void _emitAwaiting() {
    final intent = _latest;
    _emit(
      intent != null &&
              intent.status == UqpayIntentStatus.requiresCustomerAction &&
              intent.nextAction != null
          ? UqpayPaymentPhase.awaitingCustomerAction
          : UqpayPaymentPhase.awaitingOutcome,
    );
  }

  void _emit(UqpayPaymentPhase phase) {
    if (_statusController.isClosed) {
      return;
    }
    _logger.log(
      'flow $intentId: ${phase.raw}'
      '${_latest == null ? '' : ' intent_status=${_latest!.status.raw}'}',
    );
    _statusController.add(
      UqpayPaymentStatus(
        intentId: intentId,
        phase: phase,
        intent: _latest,
        pollCount: _pollCount,
      ),
    );
  }

  /// Delivers [result] exactly once and tears everything down. A second call
  /// is a no-op.
  Future<void> _finish(UqpayPaymentResult result) async {
    if (_stage == _Stage.done) {
      return;
    }
    _stage = _Stage.done;
    _paused = false;
    // A challenge still on screen must close with the flow.
    final challengeCancel = _challengeCancel;
    _challengeCancel = null;
    if (challengeCancel != null && !challengeCancel.isCompleted) {
      challengeCancel.complete();
    }
    _activeDelay?.cancel();
    _activeDelay = null;
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
    await _housekeepPin(result);
    _logger.log('flow $intentId: result ${_describe(result)}');
    _emit(UqpayPaymentPhase.finished);
    // The result is delivered BEFORE the status stream closes: a paused or
    // slow subscriber must never hold the merchant's future hostage.
    if (!_completer.isCompleted) {
      _completer.complete(result);
    }
    unawaited(_statusController.close());
  }

  static String _describe(UqpayPaymentResult result) => switch (result) {
    UqpayPaymentCompleted() => 'completed',
    UqpayPaymentFailed(:final error) => 'failed code=${error.code.raw}',
    UqpayPaymentCanceled(:final reason) => 'canceled reason=${reason.raw}',
    UqpayPaymentPending(:final lastKnownStatus) =>
      'pending last_status=${lastKnownStatus?.raw}',
  };

  /// Releases the idempotency pin when the attempt is definitively over;
  /// keeps it when the server may still act on the same key (pending,
  /// outcome unknown, retryable transport failure, rejected token) so a
  /// retry reuses it. Storage failures never block the
  /// result.
  Future<void> _housekeepPin(UqpayPaymentResult result) async {
    final keep = switch (result) {
      UqpayPaymentPending() => true,
      UqpayPaymentFailed(:final error) =>
        error.isOutcomeUnknown ||
            error.isRetryable ||
            error.code == UqpayErrorCode.authenticationFailed,
      UqpayPaymentCompleted() || UqpayPaymentCanceled() => false,
    };
    if (!keep) {
      await _releasePin(definitive: true);
    }
  }

  /// Releases the pin. Before anything was sent, only the flow that minted
  /// the pin may release it — a concurrent flow reusing the same key may
  /// still have a send in flight. Once the server has answered
  /// [definitive]ly on this key, the key's work is done whoever minted it,
  /// and a later retry must get a fresh key rather than a replay.
  Future<void> _releasePin({bool definitive = false}) async {
    final pin = _pin;
    if (pin == null || (!_ownsPin && !definitive)) {
      return;
    }
    try {
      await _store.release(intentId: intentId, fingerprint: pin.fingerprint);
    } on Object {
      // Best effort: an unreleased pin expires in 24 h, and a
      // storage call that hangs must not delay the result.
    }
  }
}

enum _Stage { idle, preparing, confirming, awaiting, done }

/// A stream whose `onData` listeners cannot break the producer: a throwing
/// listener is reported to `FlutterError.onError` and delivery continues.
class _GuardedStream<T> extends Stream<T> {
  _GuardedStream(this._inner);

  final Stream<T> _inner;

  @override
  bool get isBroadcast => _inner.isBroadcast;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner.listen(
    onData == null
        ? null
        : (event) {
            try {
              onData(event);
            } on Object catch (error, stackTrace) {
              _reportSdkError(
                error,
                stackTrace,
                'while a UqpayPaymentFlow.status listener handled an event',
              );
            }
          },
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

/// Reports an SDK-internal error for diagnostics, and **can never throw**.
///
/// `FlutterError.reportError` is not total: formatting a stack trace that came
/// from `package:stack_trace` (which is what an async gap produces under
/// `flutter test`, and anywhere `FlutterError.demangleStackTrace` is unset)
/// trips an assertion inside `StackFrame.fromStackTraceLine`. A throwing
/// reporter would skip whatever line followed it — which, on the payment
/// flow's top-level catch, meant the merchant's `Future` was never completed
/// and the payment hung forever in debug builds.
///
/// Diagnostics must never be able to break the payment contract, so every
/// failure of the reporter itself is swallowed here.
void _reportSdkError(Object error, StackTrace stackTrace, String context) {
  try {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'uqpay_sdk_flutter',
        context: ErrorDescription(context),
      ),
    );
  } on Object catch (_) {
    // Deliberately empty: a diagnostics channel that fails must stay silent
    // rather than take the payment down with it.
  }
}
