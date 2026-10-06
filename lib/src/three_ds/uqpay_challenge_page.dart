import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/l10n/uqpay_localizations.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_outcome.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_presenter.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/webview_challenge_presenter_stub.dart'
    if (dart.library.js_interop) 'package:uqpay_sdk_flutter/src/three_ds/webview_challenge_presenter_stub.dart'
    if (dart.library.io) 'package:uqpay_sdk_flutter/src/three_ds/webview_challenge_presenter_io.dart'
    as challenge_view;

/// A full-screen 3-D Secure / redirect challenge page.
///
/// Push it expecting a [UqpayChallengeOutcome] result — the route pops with
/// the outcome, or with `null` when the customer backs out (map that to
/// [UqpayChallengeOutcome.dismissedByUser]):
///
/// ```dart
/// final outcome = await Navigator.of(context).push<UqpayChallengeOutcome>(
///   MaterialPageRoute(
///     builder: (_) => UqpayChallengePage(request: request),
///     fullscreenDialog: true,
///   ),
/// );
/// ```
///
/// Or let [UqpayWebviewChallengePresenter] push it for you. On mobile the
/// body is a `webview_flutter` webview, selected by a conditional import
/// (`dart.library.io`); on web builds (`dart.library.js_interop`, JS and
/// wasm alike) `webview_flutter` is never compiled and the page completes
/// [UqpayChallengeOutcome.failed] — use `UqpayRedirectChallengePresenter`
/// there instead.
///
/// The page never reads or logs the challenge page's content, never trusts
/// the return URL's query string, and completes at most one outcome: the
/// caller must re-query the intent afterwards — `UqpayPaymentFlow` does this
/// automatically.
class UqpayChallengePage extends StatefulWidget {
  /// Creates a challenge page for [request].
  ///
  /// [clock] drives the [UqpayChallengeRequest.timeout] deadline and
  /// defaults to the real clock; tests inject a fake. [title] is
  /// the app-bar text, defaulting to `'Verification'`.
  const UqpayChallengePage({
    required this.request,
    super.key,
    this.clock,
    this.title,
  });

  /// What to present.
  final UqpayChallengeRequest request;

  /// The deadline clock; `null` means the system clock.
  final UqpayClock? clock;

  /// The app-bar title. `null` falls back to
  /// `UqpayLocalizations.verificationTitle`.
  final String? title;

  @override
  State<UqpayChallengePage> createState() => _UqpayChallengePageState();
}

class _UqpayChallengePageState extends State<UqpayChallengePage> {
  late final UqpayClock _clock = widget.clock ?? SystemUqpayClock();
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    // When the flow stops caring (cancel, dispose, resolved, bound
    // exceeded) the page closes itself instead of staying live with nobody
    // listening for its result.
    final cancelled = widget.request.cancelled;
    if (cancelled != null) {
      unawaited(
        cancelled.then<void>(
          (_) => _finish(const UqpayChallengeOutcome.dismissedByUser()),
          onError: (Object _) =>
              _finish(const UqpayChallengeOutcome.dismissedByUser()),
        ),
      );
    }
  }

  void _finish(UqpayChallengeOutcome outcome) {
    if (_completed || !mounted) {
      return;
    }
    _completed = true;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(outcome);
    } else {
      // Something sits above the page (a dialog): remove this route only,
      // never pop the unrelated one on top.
      navigator.removeRoute(route, outcome);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      // The default comes from UqpayLocalizations; `title` stays a
      // plain caller-supplied override.
      title: Text(
        widget.title ?? UqpayLocalizations.of(context).verificationTitle,
      ),
      leading: CloseButton(
        onPressed: () => _finish(const UqpayChallengeOutcome.dismissedByUser()),
      ),
    ),
    body: challenge_view.buildChallengeView(
      request: widget.request,
      clock: _clock,
      onOutcome: _finish,
    ),
  );
}

/// The mobile [UqpayChallengePresenter]: pushes a [UqpayChallengePage] on
/// the navigator you supply and completes with the page's outcome.
///
/// ```dart
/// final flow = uqpay.payments.createFlow(
///   intentId: id,
///   request: request,
///   challengePresenter: UqpayWebviewChallengePresenter(
///     navigator: () => navigatorKey.currentState!,
///   ),
/// );
/// ```
///
/// On platforms without a webview (web builds) [present] completes
/// [UqpayChallengeOutcome.failed] without pushing anything; use
/// `UqpayRedirectChallengePresenter` there.
class UqpayWebviewChallengePresenter implements UqpayChallengePresenter {
  /// Creates a presenter. [navigator] is called at present time, so a
  /// `GlobalKey<NavigatorState>`'s current state can be read lazily.
  /// [clock] and [title] are forwarded to every [UqpayChallengePage].
  UqpayWebviewChallengePresenter({
    required NavigatorState Function() navigator,
    UqpayClock? clock,
    String? title,
  }) : _navigator = navigator,
       _clock = clock,
       _title = title;

  final NavigatorState Function() _navigator;
  final UqpayClock? _clock;
  final String? _title;

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    if (!challenge_view.isWebviewChallengeSupported) {
      return UqpayChallengeOutcome.failed(_unsupportedError());
    }
    try {
      final outcome = await _navigator().push<UqpayChallengeOutcome>(
        MaterialPageRoute<UqpayChallengeOutcome>(
          builder: (_) => UqpayChallengePage(
            request: request,
            clock: _clock,
            title: _title,
          ),
          fullscreenDialog: true,
        ),
      );
      // A system back / programmatic pop without a result is a dismissal.
      return outcome ?? const UqpayChallengeOutcome.dismissedByUser();
    } on Object {
      // The exception text is deliberately not forwarded: a Navigator or
      // webview message can echo the challenge URL.
      return UqpayChallengeOutcome.failed(
        UqpayError(
          code: UqpayErrorCode.invalidConfiguration,
          developerMessage:
              'UqpayWebviewChallengePresenter could not push the challenge '
              'page (the Navigator or the webview threw).',
          userMessage: defaultUserMessage(UqpayErrorCode.invalidConfiguration),
          isRetryable: false,
        ),
      );
    }
  }

  UqpayError _unsupportedError() => UqpayError(
    code: UqpayErrorCode.invalidConfiguration,
    developerMessage:
        'UqpayWebviewChallengePresenter needs a platform webview and this '
        'platform has none (web builds must use '
        'UqpayRedirectChallengePresenter).',
    userMessage: defaultUserMessage(UqpayErrorCode.invalidConfiguration),
    isRetryable: false,
  );
}
