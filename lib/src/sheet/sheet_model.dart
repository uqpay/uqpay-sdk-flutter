/// The drop-in sheet's state machine. Internal — never exported.
///
/// The model is a plain [ChangeNotifier] over the **public headless API**:
/// everything it does — reconcile, confirm, poll, cancel — is
/// a `UqpayPayments`/`UqpayPaymentFlow` call a merchant could make
/// themselves. It holds no card data (fields live in the form widgets and
/// are read once, at pay time) and never logs anything.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// What the sheet is currently showing. One state per screen (loading,
/// empty, error-with-retry, working, result — no dead ends).
@immutable
sealed class UqpaySheetState {
  const UqpaySheetState();
}

/// The intent is being loaded (or re-loaded after a retry).
final class SheetLoadingState extends UqpaySheetState {
  /// Creates the loading state.
  const SheetLoadingState();
}

/// The intent could not be loaded; a retry affordance is shown.
final class SheetLoadFailedState extends UqpaySheetState {
  /// Creates the state. [error] is the mapped read failure, when known.
  const SheetLoadFailedState({this.error});

  /// Why the load failed, if the SDK knows.
  final UqpayError? error;
}

/// The intent offers no payment method the sheet can render.
final class SheetNoMethodsState extends UqpaySheetState {
  /// Creates the state.
  const SheetNoMethodsState({required this.cardHiddenOnWeb});

  /// Whether `card` was offered but hidden because the sheet runs in a
  /// browser (web builds have no card entry in this version).
  final bool cardHiddenOnWeb;
}

/// The payment-method list.
final class SheetMethodListState extends UqpaySheetState {
  /// Creates the state.
  const SheetMethodListState({
    required this.methods,
    required this.cardHiddenOnWeb,
  });

  /// Renderable method types, `card` pinned first, server order otherwise.
  final List<String> methods;

  /// Whether `card` was hidden because the sheet runs in a browser.
  final bool cardHiddenOnWeb;
}

/// The card entry form (mobile only — never reachable on web).
final class SheetCardFormState extends UqpaySheetState {
  /// Creates the state.
  const SheetCardFormState({this.canReturnToList = true});

  /// Whether a "back to the method list" affordance makes sense. `false`
  /// under [UqpaySheetPresentation.cardOnly], where there is no list and
  /// closing the sheet cancels the payment instead.
  final bool canReturnToList;
}

/// A confirm is in flight: the sheet is locked down and says why.
final class SheetProcessingState extends UqpaySheetState {
  /// Creates the state for [phase].
  const SheetProcessingState({required this.phase});

  /// The flow phase driving this state.
  final UqpayPaymentPhase phase;
}

/// The confirm has been accepted and the outcome is being awaited. The
/// sheet is dismissible — dismissing yields `Pending`.
final class SheetAwaitingState extends UqpaySheetState {
  /// Creates the state.
  const SheetAwaitingState({required this.verifying});

  /// Whether a verification step (3-D Secure redirect) is in progress on
  /// top of the sheet, as opposed to plain outcome polling.
  final bool verifying;
}

/// A QR code is being displayed for the customer to scan.
final class SheetQrState extends UqpaySheetState {
  /// Creates the state.
  const SheetQrState({
    required this.qr,
    required this.methodType,
    required this.remaining,
  });

  /// The server's QR payload.
  final UqpayDisplayQrCode qr;

  /// The wallet method type being paid with, e.g. `paynow`.
  final String methodType;

  /// Time left until the code expires, or `null` when the server sent no
  /// parseable expiry.
  final Duration? remaining;
}

/// Bank-transfer details are being displayed.
final class SheetBankDetailsState extends UqpaySheetState {
  /// Creates the state.
  const SheetBankDetailsState({required this.details});

  /// The server's transfer details.
  final UqpayDisplayBankDetails details;
}

/// The flow has produced its result; the result screen is shown.
final class SheetResultState extends UqpaySheetState {
  /// Creates the state.
  const SheetResultState({required this.result, this.qrExpired = false});

  /// The final result the sheet will deliver.
  final UqpayPaymentResult result;

  /// Whether this result was caused by the QR expiry lapsing (renders the
  /// explicit timeout screen).
  final bool qrExpired;
}

/// The sheet's controller: loads the intent, derives the method list, runs
/// exactly one payment flow at a time and resolves the one final result.
class UqpaySheetModel extends ChangeNotifier {
  /// Creates a model. [isWeb] gates the card form off on web builds;
  /// it defaults to [kIsWeb] and is injectable for tests.
  UqpaySheetModel({
    required this.payments,
    required this.intentId,
    required this.returnUrl,
    required UqpayClock clock,
    UqpayChallengePresenter? challengePresenter,
    this.billingDetails,
    this.allowedPaymentMethods,
    this.presentation = const UqpaySheetPresentation.methodList(),
    bool? isWeb,
  }) : _clock = clock,
       _challengePresenter = challengePresenter,
       // On a real web build the override is ignored: card entry must never
       // come back on web, whatever a caller passes.
       isWebPlatform = kIsWeb || (isWeb ?? false) {
    validatePresentation(
      presentation: presentation,
      allowedPaymentMethods: allowedPaymentMethods,
    );
  }

  /// Throws [ArgumentError] for a presentation that can never be satisfied:
  /// `singleWallet('card')`, a blank wallet, or a presentation naming a
  /// method the merchant's own [allowedPaymentMethods] excludes. Checked
  /// before any network request, so a programmer error surfaces at the
  /// call site rather than as a confusing empty sheet.
  static void validatePresentation({
    required UqpaySheetPresentation presentation,
    required Set<String>? allowedPaymentMethods,
  }) {
    final allowed = allowedPaymentMethods;
    switch (presentation) {
      case UqpayMethodListPresentation():
        return;
      case UqpayCardOnlyPresentation():
        if (allowed != null && !allowed.contains('card')) {
          throw ArgumentError.value(
            presentation,
            'presentation',
            'cardOnly() asks for card, which is not in allowedPaymentMethods '
                '($allowed). Either widen the allow-list or present a method '
                'that is in it.',
          );
        }
      case UqpaySingleWalletPresentation(:final method):
        presentation.validate();
        if (allowed != null && !allowed.contains(method.trim())) {
          throw ArgumentError.value(
            presentation,
            'presentation',
            'singleWallet("$method") is not in allowedPaymentMethods '
                '($allowed). Either widen the allow-list or present a method '
                'that is in it.',
          );
        }
    }
  }

  /// Method types the merchant permits for this payment, or `null` for no
  /// restriction. Intersected with what the intent offers; names the intent
  /// does not offer (or the sheet cannot render) are ignored rather than
  /// rejected, so a merchant can hand the same set to every intent.
  final Set<String>? allowedPaymentMethods;

  /// How the sheet opens: the method list, the card form directly, or one
  /// wallet confirmed immediately.
  final UqpaySheetPresentation presentation;

  /// Billing details supplied by the merchant, used to prefill the card
  /// form and to carry the fields the form does not ask for (phone,
  /// address). Never persisted or logged.
  final UqpayBillingDetails? billingDetails;

  /// The method-type strings the sheet can render.
  /// Types outside this set are silently hidden so a new server-side method
  /// degrades gracefully.
  static const Set<String> renderableTypes = <String>{
    'card',
    'wechatpay',
    'alipaycn',
    'alipayhk',
    'grabpay',
    'paynow',
    'unionpay',
    'truemoney',
    'tng',
    'gcash',
    'dana',
    'kakaopay',
    'tosspay',
    'naverpay',
  };

  /// The outcome deadline for card confirms.
  static const Duration cardOutcomeDeadline = Duration(minutes: 5);

  /// The outcome deadline for wallet/QR confirms.
  static const Duration walletOutcomeDeadline = Duration(minutes: 10);

  /// The headless API the sheet consumes.
  final UqpayPayments payments;

  /// The intent being paid.
  final String intentId;

  /// The merchant's registered return URL — used to recognise the end of a
  /// redirect step when the server omits its echo.
  final Uri returnUrl;

  /// Whether the card form is unavailable (web builds).
  final bool isWebPlatform;

  final UqpayClock _clock;
  final UqpayChallengePresenter? _challengePresenter;

  UqpaySheetState _state = const SheetLoadingState();
  UqpayPaymentIntent? _intent;
  UqpayPaymentFlow? _flow;
  StreamSubscription<UqpayPaymentStatus>? _statusSub;
  UqpayBrowserInfo? _snapshot;
  UqpayPaymentResult? _finalResult;
  Future<UqpayPaymentResult>? _dismissal;
  String _activeMethodType = '';
  DateTime? _qrExpiresAt;
  bool _qrExpired = false;
  UqpayDelay? _countdownTick;
  bool _disposed = false;
  bool _loadStarted = false;
  bool _rejected = false;
  bool _countdownRunning = false;
  String? _autoWallet;

  /// What the sheet is showing right now.
  UqpaySheetState get state => _state;

  /// Under [UqpaySheetPresentation.singleWallet], the wallet the widget
  /// must confirm now (it owns the device snapshot the confirm needs).
  /// Returns the method once and `null` afterwards, so a rebuild cannot
  /// confirm twice.
  String? takeAutoWallet() {
    final wallet = _autoWallet;
    _autoWallet = null;
    return wallet;
  }

  /// The intent as last read, if any.
  UqpayPaymentIntent? get intent => _intent;

  /// The result, once determined (terminal guard or finished flow).
  UqpayPaymentResult? get finalResult => _finalResult;

  /// The clock the sheet's countdowns run on.
  UqpayClock get clock => _clock;

  /// Whether user-initiated dismissal is currently allowed. `false` only
  /// while a confirm is in flight; every other state may be
  /// dismissed with the semantics of [resolveDismissal].
  bool get canDismiss => _state is! SheetProcessingState;

  /// Formats the intent's amount for display — the **one** code path every
  /// screen and every status uses (an earlier native SDK divided the
  /// PENDING amount by 100 on a separate path). Returns `null` when the
  /// intent (or its amount) has not been read yet.
  String? formattedAmount(Locale locale) {
    final amount = _intent?.amount;
    final currency = _intent?.currency;
    if (amount == null || currency == null) {
      return null;
    }
    return amount.format(currencyCode: currency, locale: locale.toString());
  }

  /// Puts the sheet straight onto a failed result with [error] and never
  /// loads or pays — used when another sheet already owns this intent,
  /// so a second sheet cannot confirm the same payment.
  void rejectAsDuplicate(UqpayError error) {
    _loadStarted = true;
    _rejected = true;
    _deliver(UqpayPaymentFailed(intentId: intentId, error: error));
  }

  /// [load]s on the first call and is a no-op afterwards — so a widget can
  /// call it from `initState` without re-reading the intent on rebuilds.
  Future<void> ensureLoaded() {
    if (_loadStarted) {
      return Future<void>.value();
    }
    return load();
  }

  /// Loads (or reloads) the intent and derives the first screen. Runs the
  /// terminal-intent guard: a terminal or authorised intent goes
  /// straight to the result screen and never renders a working form.
  Future<void> load() async {
    if (_rejected) {
      return;
    }
    _loadStarted = true;
    _setState(const SheetLoadingState());
    final read = await payments.retrieveIntent(intentId);
    if (_disposed || _finalResult != null) {
      return;
    }
    switch (read) {
      case UqpayIntentUnavailable(:final error):
        _setState(SheetLoadFailedState(error: error));
      case UqpayIntentRetrieved(:final intent):
        _intent = intent;
        final status = intent.status;
        if (status.isTerminal || status.isSuccess) {
          // Terminal (or authorised) already: the sheet's result is the
          // server's — mapped by the SDK's one mapper via reconcile,
          // never by sheet-local logic.
          final result = await payments.reconcile(intentId);
          if (_disposed || _finalResult != null) {
            return;
          }
          _intent = result.intent ?? _intent;
          _deliver(result);
          return;
        }
        if (status == UqpayIntentStatus.requiresCustomerAction &&
            intent.nextAction != null) {
          // A customer action is already outstanding (QR issued, challenge
          // pending): re-serve it and await the outcome — never confirm a
          // second time.
          _activeMethodType = intent.paymentMethod?.type ?? '';
          _startFlow(request: null, outcomeDeadline: walletOutcomeDeadline);
          return;
        }
        if (status.shouldPoll) {
          // PENDING / PROCESSING / an unknown status: a payment is already
          // in flight — watch it rather than offer a second attempt.
          _activeMethodType = intent.paymentMethod?.type ?? '';
          _startFlow(request: null, outcomeDeadline: walletOutcomeDeadline);
          return;
        }
        // REQUIRES_PAYMENT_METHOD: a fresh (or retryable) intent.
        _showMethodsFor(intent);
    }
  }

  /// Opens the card form. A programmer error on web builds — the list never
  /// offers card there.
  void selectCard() {
    assert(!isWebPlatform, 'card entry is not available on web');
    _setState(const SheetCardFormState());
  }

  /// Returns from the card form to the method list.
  void backToMethods() {
    final intent = _intent;
    if (intent != null) {
      _showMethodsFor(intent);
    }
  }

  /// After a failed (but not terminal) attempt: reload the intent and offer
  /// a fresh method selection.
  Future<void> tryAgain() {
    if (_rejected) {
      return Future<void>.value();
    }
    _flow = null;
    _finalResult = null;
    _dismissal = null;
    _qrExpired = false;
    return load();
  }

  /// Whether the current result screen may offer [tryAgain]: the attempt
  /// failed but the intent itself is still payable.
  bool get canTryAgain =>
      !_rejected &&
      _state is SheetResultState &&
      (_state as SheetResultState).result is UqpayPaymentFailed &&
      _intent?.status.isTerminal != true;

  /// Confirms with card details. Values are read once, sent, and never
  /// stored or logged by the sheet. No-op when a flow is
  /// already running (N taps produce one confirm).
  void payWithCard({
    required String cardNumber,
    required String expiryMonth,
    required String expiryYear,
    required String cvc,
    required String cardholderName,
    required String email,
    required String street,
    required String city,
    required String state,
    required String postcode,
    required String countryCode,
    required String? network,
    required UqpayBrowserInfo deviceSnapshot,
  }) {
    if (_flow != null || _finalResult != null) {
      return;
    }
    _activeMethodType = 'card';
    final name = cardholderName.trim();
    final request = UqpayConfirmRequest(
      paymentMethod: UqpayConfirmPaymentMethod.card(
        UqpayCardDetails(
          cardName: name,
          cardNumber: cardNumber,
          expiryMonth: expiryMonth,
          expiryYear: expiryYear,
          cvc: cvc,
          network: network,
          // The gateway requires email and an address carrying country_code,
          // city, street, postcode and — for countries that have them —
          // state, rejecting the payment outright without any one of them and
          // naming a single field per attempt (observed against the
          // sandbox: SG passed without a state, US did not). The form
          // requires a state only for countries known to need one and the
          // field is sent only when filled. The phone number it does not ask
          // for rides along from the merchant's billing details.
          // first_name / last_name are gateway-mandatory too; the SDK
          // derives them from the cardholder name (UqpayCardDetails).
          billing: UqpayBillingDetails(
            email: email,
            phoneNumber: billingDetails?.phoneNumber,
            address: UqpayAddress(
              countryCode: countryCode,
              state: state.trim().isEmpty ? null : state.trim(),
              city: city,
              street: street,
              postcode: postcode,
            ),
          ),
        ),
      ),
      browserInfo: _snapshotOnce(deviceSnapshot),
    );
    _startFlow(request: request, outcomeDeadline: cardOutcomeDeadline);
  }

  /// Confirms with a wallet method — the shared QR/redirect path every
  /// wallet uses. No-op when a flow is already
  /// running.
  void payWithWallet(String type, {required UqpayBrowserInfo deviceSnapshot}) {
    if (_flow != null || _finalResult != null) {
      return;
    }
    _activeMethodType = type;
    final request = UqpayConfirmRequest(
      paymentMethod: UqpayConfirmPaymentMethod.wallet(
        type,
        const UqpayWalletDetails(),
      ),
      browserInfo: _snapshotOnce(deviceSnapshot),
    );
    _startFlow(request: request, outcomeDeadline: walletOutcomeDeadline);
  }

  /// Suspends the running flow (app went to background). Nothing is sent
  /// until [resume].
  void pause() => _flow?.pause();

  /// Resumes the running flow. The flow reconciles with the server
  /// immediately, before the sheet shows anything stale.
  void resume() => _flow?.resume();

  /// The ONE dismissal path: system back, swipe-down, tap-outside,
  /// the close button and a merchant `Navigator.pop` all resolve here.
  ///
  /// Semantics: a result that is already determined is returned
  /// as-is; before any confirm has left the device the result is
  /// `Canceled` with [reason]; once the confirm has left, `Pending`.
  /// Idempotent — every caller gets the same future, so the result is
  /// delivered exactly once.
  Future<UqpayPaymentResult> resolveDismissal(UqpayCancelReason reason) {
    final existing = _dismissal;
    if (existing != null) {
      return existing;
    }
    final done = _finalResult;
    if (done != null) {
      return _dismissal = Future<UqpayPaymentResult>.value(done);
    }
    final flow = _flow;
    if (flow != null && flow.hasStarted) {
      // Once a flow has started, its result is the only truth — even when it
      // is already done (or finishing) but has not reached the sheet yet: a
      // SUCCEEDED payment must never be reported as Canceled. cancel() is a
      // no-op on a finished flow.
      flow.cancel(reason);
      return _dismissal = flow.result.then((result) {
        _finalResult ??= result;
        return _finalResult!;
      });
    }
    final result = UqpayPaymentCanceled(
      intentId: intentId,
      reason: reason,
      intent: _intent,
    );
    _finalResult = result;
    return _dismissal = Future<UqpayPaymentResult>.value(result);
  }

  @override
  void dispose() {
    _disposed = true;
    _countdownTick?.cancel();
    _countdownTick = null;
    unawaited(_statusSub?.cancel());
    _statusSub = null;
    // If the widget tree vanished with a flow still running and nobody
    // resolved a dismissal (an embedded sheet being removed), call the
    // payment off so no timer or subscription outlives the sheet.
    final flow = _flow;
    if (flow != null && !flow.isDone && _dismissal == null) {
      flow.cancel(UqpayCancelReason.userDismissed);
    }
    super.dispose();
  }

  // ---- internals ----------------------------------------------------------

  UqpayBrowserInfo _snapshotOnce(UqpayBrowserInfo fresh) {
    // Frozen with the first attempt so a retried confirm body stays
    // byte-identical and reuses its idempotency pin.
    return _snapshot ??= fresh;
  }

  void _showMethodsFor(UqpayPaymentIntent intent) {
    final available = intent.availablePaymentMethodTypes ?? const <String>[];
    final allowed = allowedPaymentMethods;
    final seen = <String>{};
    final methods = <String>[
      for (final type in available)
        if (renderableTypes.contains(type) &&
            (allowed == null || allowed.contains(type)) &&
            seen.add(type))
          type,
    ];
    final hadCard = methods.remove('card');
    var cardHidden = false;
    if (hadCard) {
      if (isWebPlatform) {
        cardHidden = true; // No card entry on web.
      } else {
        methods.insert(0, 'card'); // Pinned first, stable partition.
      }
    }
    switch (presentation) {
      case UqpayMethodListPresentation():
        if (methods.isEmpty) {
          _setState(SheetNoMethodsState(cardHiddenOnWeb: cardHidden));
        } else {
          _setState(
            SheetMethodListState(methods: methods, cardHiddenOnWeb: cardHidden),
          );
        }
      case UqpayCardOnlyPresentation():
        // Straight to the form; no list exists to go back to, so the only
        // way out is closing the sheet, which cancels (Android parity).
        if (hadCard && !isWebPlatform) {
          _setState(const SheetCardFormState(canReturnToList: false));
        } else {
          _setState(SheetNoMethodsState(cardHiddenOnWeb: cardHidden));
        }
      case UqpaySingleWalletPresentation(:final method):
        final wallet = method.trim();
        if (methods.contains(wallet) && wallet != 'card') {
          // The widget confirms on the next turn with its device snapshot;
          // until then the sheet shows the working screen, never a list.
          _autoWallet = wallet;
          _setState(
            const SheetProcessingState(phase: UqpayPaymentPhase.preparing),
          );
        } else {
          _setState(SheetNoMethodsState(cardHiddenOnWeb: cardHidden));
        }
    }
  }

  void _startFlow({
    required UqpayConfirmRequest? request,
    required Duration outcomeDeadline,
  }) {
    _setState(
      const SheetProcessingState(phase: UqpayPaymentPhase.preparing),
    );
    final flow = payments.createFlow(
      intentId: intentId,
      request: request,
      outcomeDeadline: outcomeDeadline,
      challengePresenter: _challengePresenter,
    );
    _flow = flow;
    _statusSub = flow.status.listen(_onStatus);
    unawaited(request == null ? flow.awaitOutcome() : flow.confirm());
    unawaited(flow.result.then(_onFlowResult));
  }

  void _onStatus(UqpayPaymentStatus status) {
    if (_disposed || _finalResult != null) {
      return;
    }
    _intent = status.intent ?? _intent;
    final phase = status.phase;
    if (phase == UqpayPaymentPhase.preparing ||
        phase == UqpayPaymentPhase.confirming ||
        phase == UqpayPaymentPhase.retrying) {
      _setState(SheetProcessingState(phase: phase));
      return;
    }
    if (phase == UqpayPaymentPhase.awaitingCustomerAction) {
      final action = status.nextAction;
      final type = action?.type;
      if (type == UqpayNextActionType.displayQrCode &&
          action?.displayQrCode != null) {
        _showQr(action!.displayQrCode!);
        return;
      }
      if (type == UqpayNextActionType.displayBankDetails &&
          action?.displayBankDetails != null) {
        _setState(SheetBankDetailsState(details: action!.displayBankDetails!));
        return;
      }
      // redirect_to_url / redirect_iframe are presented by the challenge
      // presenter on top of the sheet; unknown actions poll through.
      final verifying =
          type == UqpayNextActionType.redirectToUrl ||
          type == UqpayNextActionType.redirectIframe;
      _setState(SheetAwaitingState(verifying: verifying));
      return;
    }
    if (phase == UqpayPaymentPhase.awaitingOutcome) {
      _stopCountdown();
      _setState(const SheetAwaitingState(verifying: false));
      return;
    }
    // `paused` keeps the current screen; `finished` is handled by the
    // result future; unknown phases are "still working" by contract.
  }

  Future<void> _onFlowResult(UqpayPaymentResult result) async {
    _stopCountdown();
    if (_disposed || _dismissal != null) {
      // A dismissal is already delivering this result through its own
      // future; do not also show a result screen mid-close.
      _finalResult ??= result;
      return;
    }
    _deliver(result);
  }

  void _deliver(UqpayPaymentResult result) {
    _finalResult ??= result;
    _setState(
      SheetResultState(result: _finalResult!, qrExpired: _qrExpired),
    );
  }

  void _showQr(UqpayDisplayQrCode qr) {
    // Re-parsed on every serve: a re-issued QR carries its own expiry, and
    // the countdown must follow the code actually on screen.
    _qrExpiresAt = parseQrExpiry(qr.expiresAt, now: _clock.now());
    _setState(
      SheetQrState(
        qr: qr,
        methodType: _activeMethodType,
        remaining: _qrRemaining(),
      ),
    );
    if (!_countdownRunning && _qrExpiresAt != null) {
      unawaited(_runCountdown());
    }
  }

  /// The longest QR lifetime the sheet will count down. Anything further out
  /// (a garbage timestamp, an epoch number read as a year) shows no
  /// countdown rather than an absurd one.
  static const Duration maxQrLifetime = Duration(hours: 24);

  /// Parses a QR `expires_at` as UTC. A timestamp without a UTC offset is
  /// read as UTC — never device-local time — and one more than
  /// [maxQrLifetime] after [now] is ignored. Returns `null` when absent or
  /// unparseable.
  @visibleForTesting
  static DateTime? parseQrExpiry(String? raw, {required DateTime now}) {
    if (raw == null) {
      return null;
    }
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed == null) {
      return null;
    }
    // Dart returns a UTC instant when the string has `Z` or an offset, and
    // a local one when it has neither.
    final utc = parsed.isUtc
        ? parsed
        : DateTime.utc(
            parsed.year,
            parsed.month,
            parsed.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
            parsed.millisecond,
            parsed.microsecond,
          );
    if (utc.difference(now) > maxQrLifetime) {
      return null;
    }
    return utc;
  }

  Duration? _qrRemaining() {
    final expiresAt = _qrExpiresAt;
    if (expiresAt == null) {
      return null;
    }
    final remaining = expiresAt.difference(_clock.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Ticks the visible QR countdown once a second off the injected clock
  /// and, when the expiry lapses, calls the flow off so the sheet
  /// reports an explicit timeout instead of waiting forever — and never a
  /// success the server didn't confirm (a defect seen in an earlier
  /// native SDK).
  Future<void> _runCountdown() async {
    _countdownRunning = true;
    try {
      await _countdownLoop();
    } finally {
      _countdownRunning = false;
    }
  }

  Future<void> _countdownLoop() async {
    while (!_disposed && _finalResult == null && _state is SheetQrState) {
      final remaining = _qrRemaining();
      if (remaining == null) {
        return;
      }
      if (remaining <= Duration.zero) {
        _qrExpired = true;
        // The confirm has left the device (a QR exists only after one), so
        // this resolves Pending — the honest answer: a last-second scan may
        // still settle; the merchant reconciles or awaits the webhook.
        _flow?.cancel(UqpayCancelReason.fromRaw('qr_expired'));
        return;
      }
      final current = _state;
      if (current is SheetQrState && current.remaining != remaining) {
        _setState(
          SheetQrState(
            qr: current.qr,
            methodType: current.methodType,
            remaining: remaining,
          ),
        );
      }
      final tick = _clock.startDelay(const Duration(seconds: 1));
      _countdownTick = tick;
      await tick.future;
      if (identical(_countdownTick, tick)) {
        _countdownTick = null;
      }
    }
  }

  void _stopCountdown() {
    _countdownTick?.cancel();
    _countdownTick = null;
  }

  void _setState(UqpaySheetState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    notifyListeners();
  }
}
