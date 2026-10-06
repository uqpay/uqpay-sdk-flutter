import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_next_action.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_outcome.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/uqpay_challenge_presenter.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// The web challenge presenter: a **full-page redirect** in the
/// same tab, never a popup and never an embedded webview.
///
/// This *is* the fallback design promoted to the only design: because
/// the challenge takes over the first-party page, popup blocking cannot stop
/// it and third-party-cookie / cross-site-tracking prevention (iOS Safari)
/// cannot break the ACS session — there is no third-party context at all.
///
/// Sequence:
///
/// 1. [present] durably records the in-flight intent id under
///    [pendingIntentKey] (persistent storage, `localStorage` on web) so
///    the app can recover it after the page reload;
/// 2. it then navigates the tab to the challenge URL
///    (`webOnlyWindowName: '_self'`);
/// 3. the bank sends the customer back to the merchant's `return_url`; on
///    that reload the app calls `UqpayReturnHandler.consume(Uri.base)`,
///    which re-queries the server and maps *its* status.
///
/// Nothing sensitive is ever placed in the URL or storage: the only
/// value written is the server-opaque intent id, which is useless without
/// the merchant's token provider. On a successful redirect the returned
/// future **never completes** — the page unloads; the outcome is recovered
/// through `UqpayReturnHandler`. It completes only with
/// [UqpayChallengeOutcome.failed] when the redirect could not be started.
///
/// Also usable on mobile as an external-browser fallback: outside the web,
/// `webOnlyWindowName` is ignored and the URL opens in the default browser.
class UqpayRedirectChallengePresenter implements UqpayChallengePresenter {
  /// Creates a redirect presenter. [store] and [launch] are injectable for
  /// tests; production uses the shared-preferences store (`localStorage` on
  /// web) and `url_launcher`.
  UqpayRedirectChallengePresenter({
    KeyValueStore? store,
    Future<bool> Function(Uri url)? launch,
  }) : _store = store ?? SharedPreferencesKeyValueStore(),
       _launch = launch ?? _defaultLaunch;

  /// Where the in-flight intent id is persisted between the redirect and
  /// the return reload. Single slot: the last redirect wins.
  static const String pendingIntentKey = 'uqpay.redirect.pending';

  final KeyValueStore _store;
  final Future<bool> Function(Uri url) _launch;

  static Future<bool> _defaultLaunch(Uri url) =>
      launcher.launchUrl(url, webOnlyWindowName: '_self');

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    if (request.action.type != UqpayNextActionType.redirectToUrl) {
      return UqpayChallengeOutcome.failed(
        _error(
          'UqpayRedirectChallengePresenter can only present redirect_to_url; '
          'got ${request.action.type?.raw ?? 'no recognisable action'}. '
          'redirect_iframe (a self-submitting POST form) cannot be a '
          'full-page GET redirect.',
        ),
      );
    }
    final raw = request.action.redirectToUrl?.url;
    final url = raw == null ? null : Uri.tryParse(raw);
    if (url == null) {
      return UqpayChallengeOutcome.failed(
        _error('The redirect_to_url action has no usable challenge URL.'),
      );
    }
    if (!url.isScheme('https') || url.host.isEmpty) {
      // A card-authentication page is only ever opened over https —
      // the same rule as the webview presenter. Nothing is stored and
      // nothing is navigated to.
      return UqpayChallengeOutcome.failed(
        _error(
          'The redirect_to_url challenge URL must be an absolute https URL; '
          'got scheme "${url.scheme}". Refusing to open it.',
        ),
      );
    }
    // Persist BEFORE navigating away, so a return (or an abandoned tab that
    // later reloads) can always recover the intent.
    try {
      await _store.write(pendingIntentKey, request.intentId);
    } on Object {
      // Best effort: the redirect still works; recovery then relies on the
      // uqpay_intent return parameter or the idempotency pins.
    }
    var launched = false;
    try {
      launched = await _launch(url);
    } on Object {
      launched = false;
    }
    if (!launched) {
      try {
        await _store.remove(pendingIntentKey);
      } on Object {
        // Ignore: a stale slot is cleared by the next consume().
      }
      return UqpayChallengeOutcome.failed(
        _error('The browser refused to open the challenge URL.'),
      );
    }
    if (kIsWeb) {
      // The page is unloading; normally this future is never observed to
      // complete. If the unload is cancelled (a `beforeunload` prompt the
      // customer declines), the flow's cancellation — or its presentation
      // bound — releases it instead of leaving it pending forever.
      final cancelled = request.cancelled;
      if (cancelled == null) {
        return Completer<UqpayChallengeOutcome>().future;
      }
      try {
        await cancelled;
      } on Object {
        // Treated like a completion.
      }
      return const UqpayChallengeOutcome.dismissedByUser();
    }
    // On Android / iOS the external browser is out of sight: the hand-off
    // has ended as far as this app can tell, so report it and let the flow
    // poll the server for the outcome — never an unbounded wait.
    return const UqpayChallengeOutcome.dismissedByUser();
  }

  UqpayError _error(String developerMessage) => UqpayError(
    code: UqpayErrorCode.invalidConfiguration,
    developerMessage: developerMessage,
    userMessage: defaultUserMessage(UqpayErrorCode.invalidConfiguration),
    isRetryable: false,
  );
}
