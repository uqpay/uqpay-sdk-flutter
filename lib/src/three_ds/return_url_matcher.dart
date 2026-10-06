import 'package:flutter/foundation.dart';

/// Return-URL recognition for challenge presenters.
///
/// A navigation "is" the return when scheme, host and port match and its
/// path starts with the return URL's path (segment-aligned). Extra query
/// parameters and fragments are allowed — the ACS appends its own — and are
/// never read for a payment status.
abstract final class UqpayReturnUrlMatcher {
  /// Whether [candidate] counts as arriving at [returnUrl].
  ///
  /// Rules: scheme and host compare case-insensitively; ports must be equal
  /// after default-port normalisation; [candidate]'s path must equal
  /// [returnUrl]'s path or extend it at a `/` boundary (`/return` matches
  /// `/return/done` but not `/returnable`). Query and fragment are ignored.
  static bool matches({required Uri candidate, required Uri returnUrl}) {
    if (candidate.scheme.toLowerCase() != returnUrl.scheme.toLowerCase()) {
      return false;
    }
    if (candidate.host.toLowerCase() != returnUrl.host.toLowerCase()) {
      return false;
    }
    if (candidate.port != returnUrl.port) {
      return false;
    }
    return _pathExtends(base: returnUrl.path, path: candidate.path);
  }

  static bool _pathExtends({required String base, required String path}) {
    final wanted = _trimSlashes(base);
    final actual = _trimSlashes(path);
    if (wanted.isEmpty) {
      return true;
    }
    return actual == wanted || actual.startsWith('$wanted/');
  }

  static String _trimSlashes(String path) {
    var p = path;
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}

/// What the mobile challenge webview does with one navigation request
/// (see [challengeNavigationFor]).
enum ChallengeNavigationKind {
  /// Let the webview load it (ordinary ACS pages, interstitials).
  load,

  /// The browser step is over: complete `UqpayChallengeOutcome.returned`
  /// with [ChallengeNavigation.uri] and keep the webview where it is.
  returned,

  /// Hand [ChallengeNavigation.uri] to the OS (a banking app, `tel:`,
  /// `mailto:`, a store link) and keep the challenge open.
  launchExternally,

  /// Neither load nor launch it, and keep the challenge open.
  block,
}

/// The decision [challengeNavigationFor] returns.
@immutable
class ChallengeNavigation {
  /// Creates a decision of [kind] about [uri].
  const ChallengeNavigation(this.kind, [this.uri]);

  /// What to do.
  final ChallengeNavigationKind kind;

  /// The parsed navigation target; `null` for [ChallengeNavigationKind.load]
  /// of an unparseable URL.
  final Uri? uri;
}

/// Schemes the webview loads itself.
const Set<String> _webSchemes = <String>{
  'http',
  'https',
  'about',
  'data',
  'blob',
  '',
};

/// Schemes that are never handed to the OS and never end the challenge:
/// local files, content providers, script URLs and browser-internal pages.
const Set<String> _neverLaunchSchemes = <String>{
  'file',
  'content',
  'javascript',
  'vbscript',
  'filesystem',
  'view-source',
  'chrome',
  'chrome-error',
};

/// Communication schemes that are obviously not an app return, even under
/// the no-return-URL sentinel.
const Set<String> _utilitySchemes = <String>{'tel', 'mailto', 'sms'};

/// The scheme of the flow's "no return URL known" sentinel
/// (`uqpay-return://none`).
const String challengeReturnSentinelScheme = 'uqpay-return';

/// The navigation policy of the mobile challenge webview, pure so it can be
/// tested without a webview.
///
/// * Sub-frame navigations never end the challenge: web schemes load,
///   anything else is blocked (an "is the bank app installed?" probe frame
///   must neither end the step nor open an app).
/// * A main-frame navigation ends the challenge **only** when it matches
///   [returnUrl] ([UqpayReturnUrlMatcher.matches]: same scheme, host, port
///   and path prefix) or, when [returnUrl] uses a custom app scheme, uses
///   that same scheme.
/// * With the sentinel return URL (`uqpay-return://none`) the app scheme is
///   unknown, so any main-frame non-web scheme still ends the step (the old
///   rule), except `tel:`, `mailto:` and `sms:`, which are launched.
/// * Any other non-web main-frame scheme (`intent:`, a banking-app deep link,
///   `itms-apps:`) is launched externally and the challenge stays open.
/// * `file:`, `content:`, `javascript:` and browser-internal schemes are
///   blocked; `http(s)`, `about:`, `data:`, `blob:` and unparseable URLs load.
ChallengeNavigation challengeNavigationFor({
  required String navigationUrl,
  required Uri returnUrl,
  required bool isMainFrame,
}) {
  final candidate = Uri.tryParse(navigationUrl);
  if (candidate == null) {
    return const ChallengeNavigation(ChallengeNavigationKind.load);
  }
  final scheme = candidate.scheme.toLowerCase();
  if (_webSchemes.contains(scheme)) {
    if (isMainFrame &&
        UqpayReturnUrlMatcher.matches(
          candidate: candidate,
          returnUrl: returnUrl,
        )) {
      return ChallengeNavigation(ChallengeNavigationKind.returned, candidate);
    }
    return ChallengeNavigation(ChallengeNavigationKind.load, candidate);
  }
  if (!isMainFrame || _neverLaunchSchemes.contains(scheme)) {
    return ChallengeNavigation(ChallengeNavigationKind.block, candidate);
  }
  final returnScheme = returnUrl.scheme.toLowerCase();
  if (returnScheme == challengeReturnSentinelScheme) {
    return _utilitySchemes.contains(scheme)
        ? ChallengeNavigation(
            ChallengeNavigationKind.launchExternally,
            candidate,
          )
        : ChallengeNavigation(ChallengeNavigationKind.returned, candidate);
  }
  if (!_webSchemes.contains(returnScheme) && scheme == returnScheme) {
    return ChallengeNavigation(ChallengeNavigationKind.returned, candidate);
  }
  return ChallengeNavigation(
    ChallengeNavigationKind.launchExternally,
    candidate,
  );
}
