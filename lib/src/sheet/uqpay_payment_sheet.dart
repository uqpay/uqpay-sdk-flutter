import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/l10n/l10n_fallbacks.dart';
import 'package:uqpay_sdk_flutter/src/sheet/device_snapshot.dart';
import 'package:uqpay_sdk_flutter/src/sheet/sheet_model.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/announcements.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/card_form_view.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/method_list_view.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/qr_screen_view.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/status_views.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// The UQPAY drop-in payment sheet.
///
/// The one-line integration is the static [present] method, which shows the
/// sheet as a Material 3 modal bottom sheet and returns the payment's typed
/// result:
///
/// ```dart
/// final result = await UqpayPaymentSheet.present(
///   context,
///   payments: uqpay.payments,
///   intentId: intentId,
///   returnUrl: Uri.parse('myapp://payment-return'),
/// );
/// ```
///
/// The widget itself is embeddable: build it anywhere (a page, a dialog, a
/// custom container) and receive the result through [onResult].
///
/// The sheet is a **consumer of the public headless API** — everything it
/// does is a `UqpayPayments` / `UqpayPaymentFlow` call you could make
/// yourself; an import-boundary test enforces that it touches no
/// SDK internals. Behavioural contract highlights:
///
/// * Terminal intents show their result immediately and never render a
///   working form.
/// * While a confirm is in flight the sheet cannot be dismissed and says
///   why; dismissing at any other time resolves `Canceled` before a confirm
///   has left the device and `Pending` after.
/// * On **web** the card form never renders: card entry stays off web in
///   this version and the sheet offers the intent's wallet/QR/redirect methods
///   instead, with the limitation stated on-screen.
/// * Appearance derives from the host `Theme` — light and dark both follow
///   the host `ThemeMode`, never forced — with optional
///   [UqpayAppearance] overrides.
class UqpayPaymentSheet extends StatefulWidget {
  /// Creates an embeddable payment sheet.
  ///
  /// [payments] is the headless API from `UqpaySdk.payments`. [returnUrl]
  /// must be the return URL registered on the intent at creation — it is
  /// used to recognise the end of a 3-D Secure / wallet redirect when the
  /// server omits its echo. [onResult] receives the final
  /// [UqpayPaymentResult] exactly once. [clock] injects the time source for
  /// countdowns (tests use a fake; `null` means the system clock).
  /// [isWebPlatform] overrides the web-platform detection **for tests
  /// only**; production code must leave it `null`.
  const UqpayPaymentSheet({
    required this.payments,
    required this.intentId,
    required this.returnUrl,
    this.appearance,
    this.billingDetails,
    this.allowedPaymentMethods,
    this.presentation = const UqpaySheetPresentation.methodList(),
    this.challengePresenter,
    this.localizations,
    this.onResult,
    this.clock,
    @visibleForTesting this.isWebPlatform,
    super.key,
  }) : _model = null;

  const UqpayPaymentSheet._presented({
    required UqpaySheetModel model,
    required this.payments,
    required this.intentId,
    required this.returnUrl,
    required this.appearance,
    required this.localizations,
    required this.onResult,
  }) : _model = model,
       // The presented model already carries the billing details; the widget
       // reads them from it rather than holding a second copy.
       billingDetails = null,
       allowedPaymentMethods = null,
       presentation = const UqpaySheetPresentation.methodList(),
       challengePresenter = null,
       clock = null,
       isWebPlatform = null;

  /// The headless payment API this sheet drives.
  final UqpayPayments payments;

  /// The intent being paid.
  final String intentId;

  /// The merchant's registered return URL for redirect steps.
  final Uri returnUrl;

  /// Optional theming overrides.
  final UqpayAppearance? appearance;

  /// Billing details your app already knows, used to **prefill** the card
  /// form's name and email and to carry the phone and address the form does
  /// not ask for. The customer can edit every prefilled value; what is sent
  /// is what the form holds when they tap pay.
  ///
  /// Card number, expiry and security code are deliberately not prefillable.
  final UqpayBillingDetails? billingDetails;

  /// Method types the customer may use for this payment, e.g.
  /// `{'card', 'grabpay'}`; `null` (the default) allows every method the
  /// intent offers. The set is intersected with the intent's
  /// `available_payment_method_types`: names the intent does not offer are
  /// ignored, and an empty intersection shows the "no payment methods"
  /// screen rather than widening the list. Same semantics as the Android
  /// SDK's `allowedPaymentMethods`.
  final Set<String>? allowedPaymentMethods;

  /// How the sheet opens — see [UqpaySheetPresentation]. Defaults to the
  /// method list. A presentation that [allowedPaymentMethods] excludes, or
  /// `singleWallet('card')`, throws [ArgumentError] before any request.
  final UqpaySheetPresentation presentation;

  /// Presents 3-D Secure / redirect challenges. `null` picks the platform
  /// default: an in-app webview page on Android/iOS, a full-page redirect
  /// on web.
  final UqpayChallengePresenter? challengePresenter;

  /// Overrides the sheet's strings. `null` uses the ambient
  /// [UqpayLocalizations] (English by default).
  final UqpayLocalizations? localizations;

  /// Receives the final result exactly once (embeddable use; [present]
  /// wires this internally).
  final ValueChanged<UqpayPaymentResult>? onResult;

  /// The time source for QR countdowns; `null` means the system clock.
  final UqpayClock? clock;

  /// Test-only override of the web-platform detection (no card entry on web).
  final bool? isWebPlatform;

  /// The model supplied by [present]; `null` when the widget owns its own.
  final UqpaySheetModel? _model;

  /// Intents that currently have a presented sheet.
  static final Set<String> _presentedIntents = <String>{};

  /// Presents the payment sheet for [intentId] as a modal bottom sheet and
  /// completes with the payment's result — exactly once, after the sheet
  /// has finished closing, so the caller may navigate or call `setState`
  /// immediately. The future never completes with an error
  /// for any payment outcome.
  ///
  /// Dismissal semantics: system back, swipe-down on the handle,
  /// tap-outside and a programmatic `Navigator.pop` all resolve through one
  /// path — `Canceled(userDismissed)` before a confirm has left the device,
  /// `Pending` once it has. While the confirm is actually in flight the
  /// sheet refuses to close and tells the customer why.
  ///
  /// Calling this a second time for an intent whose sheet is still open
  /// returns a `UqpayPaymentFailed` immediately instead of opening a second
  /// sheet.
  ///
  /// See the unnamed constructor for the meaning of every parameter;
  /// [useRootNavigator] chooses the navigator the sheet is pushed onto.
  static Future<UqpayPaymentResult> present(
    BuildContext context, {
    required UqpayPayments payments,
    required String intentId,
    required Uri returnUrl,
    UqpayAppearance? appearance,
    UqpayBillingDetails? billingDetails,
    Set<String>? allowedPaymentMethods,
    UqpaySheetPresentation presentation =
        const UqpaySheetPresentation.methodList(),
    UqpayChallengePresenter? challengePresenter,
    UqpayLocalizations? localizations,
    UqpayClock? clock,
    bool useRootNavigator = true,
    @visibleForTesting bool? isWebPlatform,
  }) async {
    // A programmer error throws here, synchronously, before the
    // one-sheet-per-intent guard registers the intent and before anything is
    // pushed.
    UqpaySheetModel.validatePresentation(
      presentation: presentation,
      allowedPaymentMethods: allowedPaymentMethods,
    );
    // The modal bottom sheet route cannot even build without
    // MaterialLocalizations; pushing it anyway leaves an undismissable
    // barrier and a future that never completes. Fail fast instead.
    if (Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) ==
        null) {
      throw StateError(
        'UqpayPaymentSheet.present needs MaterialLocalizations above the '
        'context it is given. Use a MaterialApp, or add '
        'DefaultMaterialLocalizations.delegate (or '
        "GlobalMaterialLocalizations.delegate) to your app's "
        'localizationsDelegates. To use the sheet without them, embed the '
        'UqpayPaymentSheet widget instead.',
      );
    }
    final l10n = localizations ?? UqpayLocalizations.of(context);
    if (_presentedIntents.contains(intentId)) {
      return UqpayPaymentFailed(
        intentId: intentId,
        error: _duplicateSheetError(intentId, l10n),
      );
    }
    // Everything below that can throw (no Navigator above [context], a
    // presenter that fails to construct) runs BEFORE the intent is marked
    // as presented, so a throw never leaves it locked for the session.
    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    final resolvedClock = clock ?? SystemUqpayClock();
    final web = isWebPlatform ?? kIsWeb;
    final presenter = _ReturnUrlDefaultingPresenter(
      inner:
          challengePresenter ??
          (web
              ? UqpayRedirectChallengePresenter()
              : UqpayWebviewChallengePresenter(
                  navigator: () => navigator,
                  clock: resolvedClock,
                  title: l10n.verificationTitle,
                )),
      returnUrl: returnUrl,
    );
    final model = UqpaySheetModel(
      payments: payments,
      intentId: intentId,
      returnUrl: returnUrl,
      clock: resolvedClock,
      challengePresenter: presenter,
      billingDetails: billingDetails,
      allowedPaymentMethods: allowedPaymentMethods,
      presentation: presentation,
      isWeb: web,
    );
    _presentedIntents.add(intentId);
    try {
      final route = ModalBottomSheetRoute<UqpayPaymentResult>(
        isScrollControlled: true,
        useSafeArea: true,
        // Tap-outside pops via `maybePop` (the route's default), which the
        // PopScope inside the frame intercepts, so all barrier dismissals
        // funnel through the single dismissal path.
        // Drag is implemented by the frame's handle so it can be refused
        // while a confirm is in flight.
        enableDrag: false,
        showDragHandle: false,
        barrierLabel: l10n.dismissBarrierLabel,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
        builder: (sheetContext) => _PresentedSheetFrame(
          model: model,
          localizations: l10n,
          // The frame hands the sheet its own pop callback: the sheet's
          // result closes the route, and the route's result is that same
          // value — one object, delivered once.
          builder: (popWith) => UqpayPaymentSheet._presented(
            model: model,
            payments: payments,
            intentId: intentId,
            returnUrl: returnUrl,
            appearance: appearance,
            localizations: localizations,
            onResult: popWith,
          ),
        ),
      );
      navigator.push(route).ignore();
      // `completed` resolves after the route's exit transition has finished
      // and its overlay entries are gone — never mid-animation.
      final popped = await route.completed;
      return popped ??
          await model.resolveDismissal(UqpayCancelReason.userDismissed);
    } finally {
      _presentedIntents.remove(intentId);
      model.dispose();
    }
  }

  /// The error a second sheet for an already-open intent resolves with.
  static UqpayError _duplicateSheetError(
    String intentId,
    UqpayLocalizations l10n,
  ) => UqpayError(
    code: UqpayErrorCode.invalidConfiguration,
    developerMessage:
        'A UqpayPaymentSheet for intent "$intentId" was opened while a sheet '
        'for that intent is already open or embedded. Await the '
        'first result before showing another sheet for the same intent.',
    userMessage: l10n.loadFailedTitle,
    isRetryable: false,
  );

  @override
  State<UqpayPaymentSheet> createState() => _UqpayPaymentSheetState();
}

class _UqpayPaymentSheetState extends State<UqpayPaymentSheet> {
  late UqpaySheetModel _model;
  late final bool _ownsModel;
  late final AppLifecycleListener _lifecycleListener;
  UqpaySheetState? _announcedFor;

  /// The intent this (embedded) sheet holds in the one-sheet-per-intent
  /// guard, or `null`
  /// when it holds none — a presented sheet's guard is owned by `present`,
  /// and a sheet rejected as a duplicate never acquired it.
  String? _guardedIntent;

  @override
  void initState() {
    super.initState();
    final provided = widget._model;
    _ownsModel = provided == null;
    _model = provided ?? _createModel();
    _attachModel();
    // Pause polling when the app leaves the foreground; on resume the
    // flow reconciles with the server before showing anything stale.
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) {
          _model.pause();
        } else if (state == AppLifecycleState.resumed) {
          _model.resume();
        }
      },
    );
  }

  /// Builds the model an embedded sheet owns, from the current widget.
  UqpaySheetModel _createModel() {
    final clock = widget.clock ?? SystemUqpayClock();
    final web = widget.isWebPlatform ?? kIsWeb;
    return UqpaySheetModel(
      payments: widget.payments,
      intentId: widget.intentId,
      returnUrl: widget.returnUrl,
      clock: clock,
      // Same platform default as `present`: the embeddable widget must
      // run 3-D Secure too, not silently wait out the deadline.
      challengePresenter: _ReturnUrlDefaultingPresenter(
        inner:
            widget.challengePresenter ??
            (web
                ? UqpayRedirectChallengePresenter()
                : UqpayWebviewChallengePresenter(
                    navigator: () => Navigator.of(context),
                    clock: clock,
                    // No title here: initState cannot read inherited
                    // localizations; the page falls back to the ambient
                    // UqpayLocalizations.verificationTitle itself.
                  )),
        returnUrl: widget.returnUrl,
      ),
      billingDetails: widget.billingDetails,
      allowedPaymentMethods: widget.allowedPaymentMethods,
      presentation: widget.presentation,
      isWeb: widget.isWebPlatform,
    );
  }

  /// Wires [_model] to this state: listens, takes the one-sheet-per-intent
  /// guard for an
  /// owned model (or rejects it as a duplicate) and starts loading.
  void _attachModel() {
    // The guard runs before the listener is attached: a duplicate is
    // rejected synchronously, possibly inside initState, where the
    // announcement in [_onModelChanged] could not look up its View yet.
    if (_ownsModel) {
      _acquireGuard();
    }
    _model.addListener(_onModelChanged);
    unawaited(_model.ensureLoaded());
  }

  /// Registers an embedded sheet's intent in the same guard `present` uses,
  /// so an embedded sheet and a presented one (or two embedded ones) can
  /// never both pay the same intent. A duplicate goes straight to a
  /// failed result, delivered after this frame.
  void _acquireGuard() {
    final intentId = _model.intentId;
    if (UqpayPaymentSheet._presentedIntents.add(intentId)) {
      _guardedIntent = intentId;
      return;
    }
    final error = UqpayPaymentSheet._duplicateSheetError(
      intentId,
      widget.localizations ?? const UqpayLocalizations(),
    );
    _model.rejectAsDuplicate(error);
    final model = _model;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final result = model.finalResult;
      if (!mounted ||
          _delivered ||
          !identical(model, _model) ||
          result == null) {
        return;
      }
      _delivered = true;
      widget.onResult?.call(result);
    });
  }

  void _releaseGuard() {
    final intentId = _guardedIntent;
    if (intentId != null) {
      UqpayPaymentSheet._presentedIntents.remove(intentId);
      _guardedIntent = null;
    }
  }

  /// Retires an owned model: it still owes [onResult] exactly one result,
  /// so the dismissal is resolved (Canceled before a confirm left,
  /// Pending after, the flow's own result once it has finished) and
  /// delivered once the flow has settled. Retiring itself does not wait.
  void _retireModel(ValueChanged<UqpayPaymentResult>? onResult) {
    _model.removeListener(_onModelChanged);
    if (!_delivered && onResult != null) {
      _delivered = true;
      unawaited(
        _model.resolveDismissal(UqpayCancelReason.userDismissed).then(onResult),
      );
    }
    _model.dispose();
    _releaseGuard();
  }

  @override
  void didUpdateWidget(UqpayPaymentSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ownsModel) {
      return; // A presented sheet's model is fixed for the route's life.
    }
    final samePayment =
        widget.intentId == oldWidget.intentId &&
        identical(widget.payments, oldWidget.payments) &&
        widget.presentation == oldWidget.presentation &&
        setEquals(
          widget.allowedPaymentMethods,
          oldWidget.allowedPaymentMethods,
        );
    if (samePayment) {
      return;
    }
    // A different payment: the old one is dismissed (its result goes to the
    // callback that was current for it) and a fresh model takes over.
    _retireModel(oldWidget.onResult);
    _delivered = false;
    _announcedFor = null;
    _model = _createModel();
    _attachModel();
  }

  @override
  void deactivate() {
    // Released when the sheet leaves the tree (not only at dispose, which
    // runs after the frame), so a replacement sheet for the same intent
    // built in the same frame is not mistaken for a duplicate.
    _releaseGuard();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (_ownsModel && _guardedIntent == null && !_delivered) {
      // Re-inserted (GlobalKey reparenting): take the guard back if free.
      if (UqpayPaymentSheet._presentedIntents.add(_model.intentId)) {
        _guardedIntent = _model.intentId;
      }
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    if (_ownsModel) {
      _retireModel(widget.onResult);
    } else {
      _model.removeListener(_onModelChanged);
    }
    super.dispose();
  }

  UqpayLocalizations get _l10n =>
      widget.localizations ?? UqpayLocalizations.of(context);

  /// Announces failures to screen readers as they appear.
  void _onModelChanged() {
    if (!mounted) {
      return;
    }
    final state = _model.state;
    // singleWallet: the model asked for an immediate confirm; the widget
    // owns the device snapshot, so it sends it on the next microtask (never
    // re-entrantly inside a notification).
    final autoWallet = _model.takeAutoWallet();
    if (autoWallet != null) {
      scheduleMicrotask(() {
        if (mounted) {
          _model.payWithWallet(autoWallet, deviceSnapshot: _deviceSnapshot());
        }
      });
    }
    if (identical(state, _announcedFor)) {
      return;
    }
    String? message;
    if (state is SheetLoadFailedState) {
      message = state.error?.userMessage ?? _l10n.loadFailedTitle;
    } else if (state is SheetResultState) {
      final result = state.result;
      if (result is UqpayPaymentFailed) {
        message = result.error.userMessage;
      }
    }
    _announcedFor = state;
    if (message != null) {
      announceForAccessibility(context, message);
    }
  }

  /// Whether `onResult` has been (or is being) delivered — it fires exactly
  /// once per sheet instance, however many times close is tapped.
  bool _delivered = false;

  Future<void> _close(UqpayCancelReason reason) async {
    if (!_model.canDismiss) {
      announceForAccessibility(context, _l10n.cannotCloseWhileProcessing);
      return;
    }
    if (_delivered) {
      return;
    }
    _delivered = true;
    final result = await _model.resolveDismissal(reason);
    widget.onResult?.call(result);
  }

  UqpayBrowserInfo _deviceSnapshot() => buildDeviceSnapshot(
    mediaQuery: MediaQuery.of(context),
    locale: Localizations.maybeLocaleOf(context) ?? const Locale('en'),
    nowUtc: _model.clock.now(),
    platform: defaultTargetPlatform,
    isWeb: _model.isWebPlatform,
  );

  Widget _bodyFor(UqpaySheetState state, UqpayLocalizations l10n) {
    switch (state) {
      case SheetLoadingState():
        return SheetLoadingView(l10n: l10n);
      case SheetLoadFailedState(:final error):
        return SheetLoadFailedView(
          l10n: l10n,
          error: error,
          onRetry: () => unawaited(_model.load()),
        );
      case SheetNoMethodsState(:final cardHiddenOnWeb):
        return SheetNoMethodsView(
          l10n: l10n,
          cardHiddenOnWeb: cardHiddenOnWeb,
          onClose: () => unawaited(_close(UqpayCancelReason.userTappedCancel)),
        );
      case SheetMethodListState(:final methods, :final cardHiddenOnWeb):
        return SheetMethodListView(
          l10n: l10n,
          methods: methods,
          cardHiddenOnWeb: cardHiddenOnWeb,
          onSelect: (type) {
            if (type == 'card') {
              _model.selectCard();
            } else {
              _model.payWithWallet(type, deviceSnapshot: _deviceSnapshot());
            }
          },
        );
      case SheetCardFormState(:final canReturnToList):
        final locale =
            Localizations.maybeLocaleOf(context) ?? const Locale('en');
        final amount = _model.formattedAmount(locale);
        return SheetCardFormView(
          l10n: l10n,
          payLabel: amount == null
              ? l10n.paySheetTitleLabel
              : l10n.payAmountLabel(amount),
          now: _model.clock.now,
          onBack: canReturnToList ? _model.backToMethods : null,
          prefillName: _prefillCardholderName(_model.billingDetails),
          prefillEmail: _model.billingDetails?.email,
          prefillAddress: _model.billingDetails?.address,
          onSubmit: (input) => _model.payWithCard(
            cardNumber: input.cardNumber,
            expiryMonth: input.expiryMonth,
            expiryYear: input.expiryYear,
            cvc: input.cvc,
            cardholderName: input.cardholderName,
            email: input.email,
            street: input.street,
            city: input.city,
            state: input.state,
            postcode: input.postcode,
            countryCode: input.countryCode,
            network: input.network,
            deviceSnapshot: _deviceSnapshot(),
          ),
        );
      case SheetProcessingState():
        return SheetProcessingView(l10n: l10n);
      case SheetAwaitingState(:final verifying):
        return SheetAwaitingView(l10n: l10n, verifying: verifying);
      case SheetQrState(:final qr, :final methodType, :final remaining):
        return SheetQrScreenView(
          l10n: l10n,
          qr: qr,
          methodType: methodType,
          remaining: remaining,
          onCancel: () => unawaited(_close(UqpayCancelReason.userTappedCancel)),
        );
      case SheetBankDetailsState(:final details):
        return SheetBankDetailsView(l10n: l10n, details: details);
      case SheetResultState(:final result, :final qrExpired):
        return SheetResultView(
          l10n: l10n,
          result: result,
          qrExpired: qrExpired,
          canTryAgain: _model.canTryAgain,
          onTryAgain: () => unawaited(_model.tryAgain()),
          onClose: () => unawaited(_close(UqpayCancelReason.userDismissed)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final hostTheme = Theme.of(context);
    final theme = (widget.appearance ?? const UqpayAppearance()).themeFor(
      hostTheme,
    );
    return _withMaterialLocalizations(
      context,
      Theme(
        data: theme,
        child: ListenableBuilder(
          listenable: _model,
          builder: (context, _) {
            final locale =
                Localizations.maybeLocaleOf(context) ?? const Locale('en');
            // ONE amount path for every screen and every intent status,
            // PENDING included.
            final amount = _model.formattedAmount(locale);
            return Material(
              type: MaterialType.transparency,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.payments.sdk.environment ==
                        UqpayEnvironment.sandbox)
                      _TestModeBanner(l10n: l10n),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 12, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                l10n.paySheetTitle,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey<String>('uqpay-close-button'),
                            onPressed: () => unawaited(
                              _close(UqpayCancelReason.userDismissed),
                            ),
                            icon: const Icon(Icons.close),
                            tooltip: l10n.closeLabel,
                            constraints: const BoxConstraints(
                              minWidth: kSheetMinTapTarget,
                              minHeight: kSheetMinTapTarget,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (amount != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: Text(
                          amount,
                          key: const ValueKey<String>('uqpay-amount'),
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    _bodyFor(_model.state, l10n),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Supplies the default (English) [MaterialLocalizations] when the host has
/// none — a `CupertinoApp` or bare `WidgetsApp` — so the embedded sheet's
/// text fields, tooltips and dropdown can build. A host that installs its
/// own Material localizations is left untouched.
Widget _withMaterialLocalizations(BuildContext context, Widget child) {
  if (Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) !=
      null) {
    return child;
  }
  if (Localizations.maybeLocaleOf(context) == null) {
    // No Localizations ancestor at all: provide the defaults outright.
    return Localizations(
      locale: const Locale('en'),
      delegates: const <LocalizationsDelegate<Object?>>[
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      child: child,
    );
  }
  return Localizations.override(
    context: context,
    delegates: const <LocalizationsDelegate<Object?>>[
      DefaultMaterialLocalizations.delegate,
    ],
    child: child,
  );
}

/// The chrome [UqpayPaymentSheet.present] wraps around the sheet: keyboard
/// avoidance, the pop interception that funnels every dismissal gesture
/// through the model's single dismissal path, and the drag handle.
class _PresentedSheetFrame extends StatefulWidget {
  const _PresentedSheetFrame({
    required this.model,
    required this.localizations,
    required this.builder,
  });

  final UqpaySheetModel model;
  final UqpayLocalizations localizations;

  /// Builds the sheet, given the callback that pops the route with the
  /// sheet's result (at most once per frame instance).
  final Widget Function(ValueChanged<UqpayPaymentResult> popWith) builder;

  @override
  State<_PresentedSheetFrame> createState() => _PresentedSheetFrameState();
}

class _PresentedSheetFrameState extends State<_PresentedSheetFrame> {
  bool _popped = false;
  double _dragExtent = 0;

  void _popWith(UqpayPaymentResult result) {
    if (_popped || !mounted) {
      return;
    }
    _popped = true;
    Navigator.of(context).pop(result);
  }

  /// The single dismissal path for system back, barrier tap and the drag
  /// handle. Refuses while a confirm is in flight.
  Future<void> _dismiss() async {
    final model = widget.model;
    if (_popped) {
      return;
    }
    if (!model.canDismiss) {
      announceForAccessibility(
        context,
        widget.localizations.cannotCloseWhileProcessing,
      );
      return;
    }
    final result = await model.resolveDismissal(
      UqpayCancelReason.userDismissed,
    );
    _popWith(result);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    // A plain Padding, deliberately not animated: the platform already
    // reports the keyboard inset frame by frame while it slides in, and
    // Flutter scrolls the focused field into view on the next frame. An extra
    // animation on top lagged behind that scroll and left the field under
    // the keyboard.
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: PopScope<UqpayPaymentResult>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            unawaited(_dismiss());
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: widget.localizations.dragHandleLabel,
              onTap: () => unawaited(_dismiss()),
              child: GestureDetector(
                key: const ValueKey<String>('uqpay-drag-handle'),
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onVerticalDragUpdate: (details) {
                  _dragExtent += details.delta.dy;
                },
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (_dragExtent > 64 || velocity > 700) {
                    unawaited(_dismiss());
                  }
                  _dragExtent = 0;
                },
                onVerticalDragCancel: () => _dragExtent = 0,
                child: SizedBox(
                  width: double.infinity,
                  height: 28,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Flexible(child: widget.builder(_popWith)),
          ],
        ),
      ),
    );
  }
}

/// Substitutes the merchant's registered return URL when the flow had none
/// to hand the presenter (the server omitted its echo and the flow fell
/// back to its unmatchable sentinel).
class _ReturnUrlDefaultingPresenter implements UqpayChallengePresenter {
  _ReturnUrlDefaultingPresenter({required this.inner, required this.returnUrl});

  /// The wrapped presenter.
  final UqpayChallengePresenter inner;

  /// The merchant's registered return URL.
  final Uri returnUrl;

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) {
    final effective = request.returnUrl.scheme == 'uqpay-return'
        ? UqpayChallengeRequest(
            intentId: request.intentId,
            action: request.action,
            returnUrl: returnUrl,
            timeout: request.timeout,
          )
        : request;
    return inner.present(effective);
  }
}

/// The single name string the card form starts with, assembled from the
/// merchant's billing details. Returns `null` when neither part is supplied,
/// so the field simply starts empty.
String? _prefillCardholderName(UqpayBillingDetails? billing) {
  final parts = <String>[
    ?billing?.firstName?.trim(),
    ?billing?.lastName?.trim(),
  ].where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? null : parts.join(' ');
}

/// The sandbox banner (Android parity): drawn on every screen of the sheet
/// whenever the SDK talks to [UqpayEnvironment.sandbox], never in
/// production. Deliberately not themeable and not suppressible by
/// [UqpayAppearance] — a tester must always be able to tell a sandbox
/// payment from a real one.
class _TestModeBanner extends StatelessWidget {
  const _TestModeBanner({required this.l10n});

  final UqpayLocalizations l10n;

  @override
  Widget build(BuildContext context) => Semantics(
    label: l10n.testModeBannerSemanticsLabel,
    excludeSemantics: true,
    child: Container(
      key: const ValueKey<String>('uqpay-test-mode-banner'),
      width: double.infinity,
      color: const Color(0xFFFFE08A),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Text(
        // A localisation override cannot blank the banner: an empty string
        // falls back to the default so sandbox is always distinguishable.
        l10n.testModeBannerLabel,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF3D2E00),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    ),
  );
}
