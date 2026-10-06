import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_next_action.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_outcome.dart';

/// Everything a presenter needs to show one challenge step.
@immutable
class UqpayChallengeRequest {
  /// Creates a challenge request.
  const UqpayChallengeRequest({
    required this.intentId,
    required this.action,
    required this.returnUrl,
    this.timeout = defaultTimeout,
    this.cancelled,
  });

  /// The default [timeout]: the 10-minute 3-D Secure ceiling.
  static const Duration defaultTimeout = Duration(minutes: 10);

  /// The intent being authenticated.
  final String intentId;

  /// The action to present: `redirect_to_url` (open
  /// [UqpayRedirectToUrl.url]) or `redirect_iframe` (load
  /// [UqpayRedirectIframe.iframe] as HTML and let it self-submit its POST
  /// form).
  final UqpayNextAction action;

  /// The merchant's return URL, used **only** as a navigation sentinel
  /// (scheme + host + path prefix; extra query and fragment allowed). Its
  /// query string is never read for a payment status.
  final Uri returnUrl;

  /// How long the presenter waits for a return before completing
  /// [UqpayChallengeOutcome.timedOut]. Measured on the SDK clock.
  ///
  /// **Suspension-tolerant** in the SDK's webview presenter: time the app
  /// spends in the background never counts — the window restarts on each
  /// return to the foreground — so approving in a banking app for longer
  /// than [timeout] cannot by itself time the challenge out.
  /// And the outcome is **fail-safe** regardless: `timedOut` is only a
  /// signal, after which the flow re-queries the server, so a challenge
  /// that actually succeeded still resolves to a completed payment.
  final Duration timeout;

  /// Completes when the caller no longer needs this presentation — the
  /// payment flow was cancelled or disposed, it resolved from the server
  /// while the challenge was still open, or the presentation outlived the
  /// flow's own bound. `null` when the caller never cancels.
  ///
  /// A presenter should then close its UI and complete [present][]
  /// promptly (any outcome; the flow no longer reads it).
  /// `UqpayChallengePage` and the SDK's presenters do this automatically;
  /// a custom presenter that ignores it leaves its UI on screen with nobody
  /// listening for the result.
  ///
  /// [present]: UqpayChallengePresenter.present
  final Future<void>? cancelled;

  /// A copy of this request with the given fields replaced. [cancelled] is
  /// carried over unless replaced, so a wrapping presenter that swaps
  /// [returnUrl] keeps the cancellation signal.
  UqpayChallengeRequest copyWith({
    String? intentId,
    UqpayNextAction? action,
    Uri? returnUrl,
    Duration? timeout,
    Future<void>? cancelled,
  }) => UqpayChallengeRequest(
    intentId: intentId ?? this.intentId,
    action: action ?? this.action,
    returnUrl: returnUrl ?? this.returnUrl,
    timeout: timeout ?? this.timeout,
    cancelled: cancelled ?? this.cancelled,
  );
}

/// Presents a 3-D Secure / redirect challenge to the customer and reports
/// how the *presentation* ended.
///
/// Headless-safe: the SDK ships `UqpayWebviewChallengePresenter` (mobile,
/// exported from the main library) and `UqpayRedirectChallengePresenter`
/// (web, full-page redirect), and a merchant can implement this interface
/// to present the challenge any other way — a Custom Tab, an external
/// browser, their own webview.
///
/// The outcome is a **signal only**: whatever it is, the payment flow
/// re-queries the intent and maps the server's status. A presenter therefore
/// cannot make a payment succeed or fail by itself, and must never read the
/// challenge page's content or trust the return URL's query string.
// ignore: one_member_abstracts -- a named public seam merchants implement.
abstract interface class UqpayChallengePresenter {
  /// Presents [request] and completes when the presentation ends. Must not
  /// throw; report problems as [UqpayChallengeOutcome.failed].
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request);
}
