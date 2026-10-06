import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/return_url_matcher.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_outcome.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_presenter.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;
import 'package:webview_flutter/webview_flutter.dart';

/// Whether a real challenge webview exists on this platform. This is the
/// mobile (`dart.library.io`) implementation: yes.
bool get isWebviewChallengeSupported => true;

/// Builds the webview body of `UqpayChallengePage`: loads the challenge,
/// watches navigations for the return URL, and reports exactly one
/// [UqpayChallengeOutcome] through [onOutcome]. Timeouts run on [clock]
/// and no timer outlives the widget.
Widget buildChallengeView({
  required UqpayChallengeRequest request,
  required UqpayClock clock,
  required void Function(UqpayChallengeOutcome outcome) onOutcome,
}) => _WebviewChallengeView(
  request: request,
  clock: clock,
  onOutcome: onOutcome,
);

/// Hands a non-web link from the challenge page (a banking app, `tel:`,
/// `mailto:`) to the OS. Replaceable in tests; production uses
/// `url_launcher` in external-application mode. Failures are swallowed by
/// the caller: the challenge simply stays open.
@visibleForTesting
Future<bool> Function(Uri uri) challengeExternalLauncher =
    _defaultExternalLaunch;

Future<bool> _defaultExternalLaunch(Uri uri) =>
    launcher.launchUrl(uri, mode: launcher.LaunchMode.externalApplication);

/// Wraps a `redirect_iframe` fragment in a document that submits its first
/// form once **that document** has loaded — the iOS and Android SDKs' shape.
///
/// The fallback submit must live inside the fragment's own document. Run
/// from the webview's page-finished callback instead, it lands on whatever
/// page is current: the fragment normally auto-submits, its own load never
/// finishes, and the first page-finished belongs to the ACS integrator page
/// — whose `form1` then posts before the 3DS method has run, failing the
/// authentication (observed against the sandbox). A `load`
/// listener dies with its document, so it can never reach the next page.
@visibleForTesting
String wrapIframeFragment(String fragment) =>
    '''
<!doctype html>
<html>
<head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0">
$fragment
<script>
(function () {
  var submit = function () {
    var forms = document.getElementsByTagName('form');
    if (forms.length > 0) { forms[0].submit(); }
  };
  if (document.readyState === 'complete') { submit(); }
  else { window.addEventListener('load', submit); }
})();
</script>
</body>
</html>
''';

class _WebviewChallengeView extends StatefulWidget {
  const _WebviewChallengeView({
    required this.request,
    required this.clock,
    required this.onOutcome,
  });

  final UqpayChallengeRequest request;
  final UqpayClock clock;
  final void Function(UqpayChallengeOutcome outcome) onOutcome;

  @override
  State<_WebviewChallengeView> createState() => _WebviewChallengeViewState();
}

class _WebviewChallengeViewState extends State<_WebviewChallengeView>
    with WidgetsBindingObserver {
  /// The base URL a `redirect_iframe` fragment is loaded against:
  /// `about:blank`'s opaque origin breaks some ACS servers,
  /// so the iOS SDK's origin is kept.
  static const String _iframeBaseUrl = 'https://uqpaytech.com';

  WebViewController? _controller;
  UqpayDelay? _deadline;
  bool _completed = false;
  bool _disposed = false;

  /// Whether the app went to the background (`paused` / `hidden`) since the
  /// deadline was last armed. Only that transition re-arms it on `resumed`:
  /// an `inactive` blip — Control Center, the notification shade, a
  /// system dialog — must not hand the customer a fresh full window.
  bool _backgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _armDeadline();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _cancelDeadline();
    _scrubSession();
    super.dispose();
  }

  /// Runs on **every** exit path — return, close button, system back,
  /// timeout, flow cancel. Clears this webview's cache and local
  /// storage. Cookies are deliberately left alone: the only cookie API is
  /// app-global and would also log the host app's own webviews out.
  void _scrubSession() {
    final controller = _controller;
    _controller = null;
    if (controller == null) {
      return;
    }
    _bestEffort(controller.clearCache);
    _bestEffort(controller.clearLocalStorage);
  }

  static void _bestEffort(Future<void> Function() op) {
    try {
      unawaited(op().then<void>((_) {}, onError: (Object _) {}));
    } on Object {
      // Hygiene must never break the teardown.
    }
  }

  /// Time spent in the background — approving in a banking app,
  /// a phone call — never counts against [UqpayChallengeRequest.timeout].
  /// The deadline is cancelled when the app is really backgrounded
  /// (`paused` / `hidden`) and re-armed in full on the return to the
  /// foreground that follows. A bare `inactive` → `resumed` toggle leaves the
  /// running deadline untouched.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_completed || _disposed) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (_backgrounded) {
        _backgrounded = false;
        _armDeadline();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgrounded = true;
      _cancelDeadline();
    }
  }

  void _finish(UqpayChallengeOutcome outcome) {
    if (_completed || _disposed) {
      return;
    }
    _completed = true;
    _cancelDeadline();
    // Session hygiene runs in dispose(), which every exit path reaches.
    widget.onOutcome(outcome);
  }

  void _load() {
    final action = widget.request.action;
    final redirect = action.redirectToUrl?.url;
    final redirectUri = redirect == null ? null : Uri.tryParse(redirect);
    final iframe = action.redirectIframe?.iframe;

    if (redirectUri == null && (iframe == null || iframe.isEmpty)) {
      _failSoon(
        'The next_action (${action.type?.raw ?? 'unknown'}) carries neither '
        'a redirect URL nor an iframe fragment; nothing can be presented.',
      );
      return;
    }
    if (redirectUri != null && !redirectUri.isScheme('https')) {
      // A challenge page over plain http (or a custom scheme) is not a 3-D
      // Secure page; refusing it keeps the card session off the clear.
      _failSoon(
        'The redirect_to_url challenge URL must be https; got '
        '"${redirectUri.scheme}".',
      );
      return;
    }

    final controller = WebViewController();
    unawaited(controller.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(
      controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onWebResourceError: _onWebResourceError,
        ),
      ),
    );
    _controller = controller;
    if (redirectUri != null) {
      unawaited(controller.loadRequest(redirectUri));
    } else {
      // The fragment holds a POST form targeting the
      // ACS; it must load as HTML and self-submit (a GET rewrite would drop
      // the POST body).
      unawaited(
        controller.loadHtmlString(
          wrapIframeFragment(iframe!),
          baseUrl: _iframeBaseUrl,
        ),
      );
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest navigation) {
    if (_completed || _disposed) {
      return NavigationDecision.prevent;
    }
    final decision = challengeNavigationFor(
      navigationUrl: navigation.url,
      returnUrl: widget.request.returnUrl,
      isMainFrame: navigation.isMainFrame,
    );
    switch (decision.kind) {
      case ChallengeNavigationKind.load:
        return NavigationDecision.navigate;
      case ChallengeNavigationKind.returned:
        _finish(UqpayChallengeOutcome.returned(decision.uri!));
        return NavigationDecision.prevent;
      case ChallengeNavigationKind.launchExternally:
        _launchExternally(decision.uri!);
        return NavigationDecision.prevent;
      case ChallengeNavigationKind.block:
        return NavigationDecision.prevent;
    }
  }

  /// Opens [uri] outside the app. The challenge stays open whatever
  /// happens: a missing app or a refused launch leaves the customer on the
  /// ACS page, which normally offers another way to authenticate.
  void _launchExternally(Uri uri) {
    try {
      unawaited(
        challengeExternalLauncher(
          uri,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Synchronous launcher failure: same as a refused launch.
    }
  }

  void _onWebResourceError(WebResourceError error) {
    if (error.isForMainFrame ?? false) {
      _finish(
        UqpayChallengeOutcome.failed(
          UqpayError(
            code: UqpayErrorCode.networkError,
            developerMessage:
                'The challenge page failed to load '
                '(${error.errorCode}: '
                '${redactCardLikeDigits(error.description)}).',
            userMessage: defaultUserMessage(UqpayErrorCode.networkError),
            isRetryable: true,
            isOutcomeUnknown: true,
          ),
        ),
      );
    }
  }

  void _failSoon(String developerMessage) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _finish(
        UqpayChallengeOutcome.failed(
          UqpayError(
            code: UqpayErrorCode.invalidConfiguration,
            developerMessage: developerMessage,
            userMessage: defaultUserMessage(
              UqpayErrorCode.invalidConfiguration,
            ),
            isRetryable: false,
          ),
        ),
      );
    });
  }

  void _armDeadline() {
    _cancelDeadline();
    final deadline = widget.clock.startDelay(widget.request.timeout);
    _deadline = deadline;
    unawaited(
      deadline.future.then((_) {
        // Cancellation also completes the future, but clears [_deadline]
        // first — the identical() check makes a cancelled deadline inert.
        if (identical(_deadline, deadline)) {
          _finish(const UqpayChallengeOutcome.timedOut());
        }
      }),
    );
  }

  void _cancelDeadline() {
    final deadline = _deadline;
    _deadline = null;
    deadline?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return WebViewWidget(controller: controller);
  }
}
