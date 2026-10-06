import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payment_result.dart';
import 'package:uqpay_sdk_flutter/src/flow/uqpay_payments.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/redirect_challenge_presenter.dart';

/// Recognises the return leg of a web redirect challenge and resolves it
/// against the **server**.
///
/// Call [consume] once at startup on web, with `Uri.base`:
///
/// ```dart
/// final handler = UqpayReturnHandler(payments: uqpay.payments);
/// final result = await handler.consume(Uri.base);
/// if (result != null) {
///   // The customer just came back from a challenge; result is the
///   // server's current view of that intent.
/// }
/// ```
///
/// ### The return contract
///
/// The intent id travels back by either of two independent channels:
///
/// * the `uqpay_intent=<intent_id>` query parameter on the return URL.
///   Merchants who template their `return_url` per intent should append it
///   (see [returnUrlFor]); the intent id is server-opaque and not sensitive.
/// * the persistent storage slot `UqpayRedirectChallengePresenter` writes
///   before redirecting — this survives even when the bank strips query
///   parameters.
///
/// The URL parameter is a *routing hint only*: the status is always fetched
/// from the server via [UqpayPayments.reconcile]; nothing else in the URL is
/// ever read. Back/forward replays at most a `GET` of the intent —
/// never a confirm.
class UqpayReturnHandler {
  /// Creates a return handler over [payments]. [store] is injectable for
  /// tests and must be the same store the presenter wrote to.
  UqpayReturnHandler({required UqpayPayments payments, KeyValueStore? store})
    : _payments = payments,
      _store = store ?? SharedPreferencesKeyValueStore();

  /// The query parameter carrying the intent id on the return URL.
  static const String intentIdParam = 'uqpay_intent';

  final UqpayPayments _payments;
  final KeyValueStore _store;

  /// Returns [returnUrl] with `uqpay_intent=<intentId>` appended — the URL a
  /// merchant should register as the intent's `return_url` when creating it,
  /// so the return leg identifies the intent even on a fresh browser.
  ///
  /// Repeated query keys already on [returnUrl] are preserved; any
  /// existing `uqpay_intent` is replaced.
  static Uri returnUrlFor(Uri returnUrl, String intentId) {
    final params = <String, List<String>>{
      for (final entry in returnUrl.queryParametersAll.entries)
        entry.key: List<String>.of(entry.value),
    }..[intentIdParam] = <String>[intentId];
    return returnUrl.replace(queryParameters: params);
  }

  /// Extracts the intent id from a return [uri], or `null`.
  ///
  /// Looks at the query string, then inside the fragment (hash-routed SPAs
  /// receive the parameter as `…#/route?uqpay_intent=…`). Malformed query
  /// encodings yield `null`, never a throw. Every occurrence of the
  /// parameter is read: blank duplicates are ignored, so
  /// `?uqpay_intent=pi_1&uqpay_intent=` still yields `pi_1`, and two
  /// *different* ids are ambiguous and yield `null`.
  static String? intentIdFromUri(Uri uri) {
    final direct = _param(uri);
    if (direct != null) {
      return direct;
    }
    final fragment = uri.fragment;
    if (fragment.isEmpty) {
      return null;
    }
    final inFragment = Uri.tryParse(fragment);
    return inFragment == null ? null : _param(inFragment);
  }

  static String? _param(Uri uri) {
    try {
      final values = <String>{
        for (final raw
            in uri.queryParametersAll[intentIdParam] ?? const <String>[])
          if (raw.trim().isNotEmpty) raw.trim(),
      };
      return values.length == 1 ? values.single : null;
    } on Object {
      // Malformed percent-encoding in the query: not a UQPAY return.
      return null;
    }
  }

  /// Recognises a challenge return in [currentUri] and resolves it.
  ///
  /// The intent id comes from the persisted pending-redirect slot when one
  /// exists — the app itself wrote it just before navigating away — and
  /// only otherwise from the `uqpay_intent` URL parameter. A URL parameter
  /// that names a *different* intent than the slot is ignored: anyone can
  /// type a URL, and a crafted one must not make the app show another
  /// payment's outcome in place of the one in flight. Returns `null` when
  /// neither identifies an intent — the app was not opened by a challenge
  /// return. Otherwise clears the slot and returns
  /// [UqpayPayments.reconcile]'s result: the server's status, never the
  /// URL's. Always compare `result.intentId` with your own order before
  /// acting on it.
  ///
  /// Never throws: a blank slot counts as no slot, a URL that cannot
  /// be decoded counts as no parameter, and a failure while resolving an
  /// identified intent yields [UqpayPaymentPending] with the error in
  /// `cause` (call its `reconcile()` to retry).
  Future<UqpayPaymentResult?> consume(Uri currentUri) async {
    String? pending;
    try {
      pending = (await _store.read(
        UqpayRedirectChallengePresenter.pendingIntentKey,
      ))?.trim();
    } on Object {
      pending = null;
    }
    String? fromUri;
    try {
      fromUri = intentIdFromUri(currentUri);
    } on Object {
      fromUri = null;
    }
    final hasPending = pending != null && pending.isNotEmpty;
    final intentId = hasPending ? pending : fromUri;
    if (pending != null) {
      try {
        await _store.remove(UqpayRedirectChallengePresenter.pendingIntentKey);
      } on Object {
        // Best effort; a stale slot only causes one extra reconcile.
      }
    }
    if (intentId == null) {
      return null;
    }
    try {
      return await _payments.reconcile(intentId);
    } on Object {
      // Deliberately not echoed: a store/transport exception text could
      // carry anything. The cause code says what the merchant needs.
      return UqpayPaymentPending(
        intentId: intentId,
        lastKnownStatus: null,
        reconcile: () => _payments.reconcile(intentId),
        cause: UqpayError(
          code: UqpayErrorCode.unknown,
          developerMessage:
              'UqpayReturnHandler could not resolve the returning intent; '
              'call reconcile() to retry.',
          userMessage: defaultUserMessage(UqpayErrorCode.unknown),
          isRetryable: true,
          isOutcomeUnknown: true,
        ),
      );
    }
  }
}
