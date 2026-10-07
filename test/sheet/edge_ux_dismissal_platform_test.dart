import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';
import 'support/sheet_screens.dart';

/// System back (Android), swipe-down (iOS), tap-outside and browser
/// back all resolve through the one dismissal path, with the same
/// semantics — Canceled before a confirm left, Pending after, refused while
/// it is in flight — on each platform.
void main() {
  const l10n = UqpayLocalizations();
  const mobile = TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.iOS,
    TargetPlatform.android,
  });

  for (final gesture in _Gesture.values) {
    group(gesture.label, () {
      testWidgets(
        'on the method list resolves Canceled(userDismissed), no confirm',
        (tester) async {
          final s = await _Session.start(tester);
          expect(find.text(l10n.chooseMethodTitle), findsOneWidget);

          await gesture.perform(tester, s);
          await pumpUntilIdle(tester, frames: 40);

          expect(s.harness.results, hasLength(1));
          final result = s.harness.results.single;
          expect(result, isA<UqpayPaymentCanceled>());
          expect(
            (result as UqpayPaymentCanceled).reason,
            UqpayCancelReason.userDismissed,
          );
          expect(s.harness.confirms, isEmpty);
          expect(find.byType(UqpayPaymentSheet), findsNothing);
        },
        variant: mobile,
      );

      testWidgets(
        'while 3-D Secure is up resolves Pending, never Canceled',
        (tester) async {
          final s = await _Session.start(
            tester,
            presenter: HangingChallengePresenter(),
            afterConfirm: intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: redirectNextAction(),
            ),
          );
          await s.payWithPayNow(tester);
          expect(find.text(l10n.verifyingTitle), findsOneWidget);
          expect(s.harness.confirms, hasLength(1));

          await gesture.perform(tester, s);
          await pumpUntilIdle(tester, frames: 40);

          expect(s.harness.results, hasLength(1));
          expect(
            s.harness.results.single,
            isA<UqpayPaymentPending>(),
            reason:
                'the confirm has left the device; the bank may still '
                'authorise it',
          );
          expect(s.harness.confirms, hasLength(1));
          expect(find.byType(UqpayPaymentSheet), findsNothing);
        },
        variant: mobile,
      );

      testWidgets(
        'on the QR screen (confirm sent) resolves Pending',
        (tester) async {
          final s = await _Session.start(
            tester,
            afterConfirm: intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextActionExpiringIn(10),
            ),
          );
          await s.payWithPayNow(tester);
          expect(find.text(l10n.qrExpiresIn('10:00')), findsOneWidget);

          await gesture.perform(tester, s);
          await pumpUntilIdle(tester, frames: 40);

          expect(s.harness.results, hasLength(1));
          expect(s.harness.results.single, isA<UqpayPaymentPending>());
          expect(s.harness.confirms, hasLength(1));
        },
        variant: mobile,
      );

      testWidgets(
        'is refused while the confirm is in flight, then the real result is '
        'delivered once',
        (tester) async {
          final confirm = Completer<UqpayHttpResponse>();
          final s = await _Session.start(tester, heldConfirm: confirm);
          await s.payWithPayNow(tester);
          expect(find.text(l10n.processingTitle), findsOneWidget);

          await gesture.perform(tester, s);
          await pumpUntilIdle(tester, frames: 40);

          expect(find.text(l10n.processingTitle), findsOneWidget);
          expect(find.text(l10n.processingBody), findsOneWidget);
          expect(s.harness.results, isEmpty);

          confirm.complete(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
          await pumpUntilIdle(tester, frames: 40);
          expect(find.text(l10n.successTitle), findsOneWidget);

          // The same gesture now closes the sheet with the real outcome.
          await gesture.perform(tester, s);
          await pumpUntilIdle(tester, frames: 40);

          expect(s.harness.results, hasLength(1));
          expect(s.harness.results.single, isA<UqpayPaymentCompleted>());
          expect(s.harness.confirms, hasLength(1));
        },
        variant: mobile,
      );
    });
  }

  group('web (isWebPlatform: true)', () {
    testWidgets('browser back on the method list resolves Canceled', (
      tester,
    ) async {
      final s = await _Session.start(tester, isWeb: true);
      expect(find.text(l10n.chooseMethodTitle), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('uqpay-method-card')),
        findsNothing,
      );

      // Flutter web routes the browser's back button to popRoute while the
      // sheet's route is on top of the navigator.
      await tester.binding.handlePopRoute();
      await pumpUntilIdle(tester, frames: 40);

      expect(s.harness.results.single, isA<UqpayPaymentCanceled>());
      expect(s.harness.confirms, isEmpty);
    });

    testWidgets('browser back while the redirect is being handed off '
        'resolves Pending', (tester) async {
      final redirect = _WebRedirect();
      final s = await _Session.start(
        tester,
        isWeb: true,
        presenter: redirect.presenter,
        afterConfirm: intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          nextAction: redirectNextAction(),
        ),
      );
      await s.payWithPayNow(tester);
      expect(find.text(l10n.verifyingTitle), findsOneWidget);
      expect(redirect.launched, hasLength(1));

      await tester.binding.handlePopRoute();
      await pumpUntilIdle(tester, frames: 40);

      expect(s.harness.results.single, isA<UqpayPaymentPending>());
      expect(s.harness.confirms, hasLength(1));
    });

    testWidgets('returning from the challenge page with no result (browser '
        'back from the ACS) leaves the intent Pending and never re-confirms', (
      tester,
    ) async {
      final redirect = _WebRedirect();
      final s = await _Session.start(
        tester,
        isWeb: true,
        presenter: redirect.presenter,
        afterConfirm: intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          nextAction: redirectNextAction(),
        ),
      );
      await s.payWithPayNow(tester);
      expect(redirect.launched, hasLength(1));
      // The pending slot was written before the tab navigated away.
      expect(
        await redirect.store.read(
          UqpayRedirectChallengePresenter.pendingIntentKey,
        ),
        kIntentId,
      );

      // Browser back from the ACS reloads the merchant page: a brand-new app
      // instance (new API object, new transport, same localStorage) whose
      // URL carries no result and no uqpay_intent parameter.
      final reloaded = SheetHarness();
      reloaded.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: redirectNextAction(),
          ),
        ),
      );
      final result = await UqpayReturnHandler(
        payments: reloaded.payments,
        store: redirect.store,
      ).consume(Uri.parse('https://shop.example/checkout'));

      expect(result, isA<UqpayPaymentPending>());
      expect(result!.intentId, kIntentId);
      expect(
        reloaded.http.requests.where((r) => r.method != 'GET'),
        isEmpty,
        reason:
            'a back/forward replay is a GET of the intent, never a '
            'confirm',
      );
    });
  });
}

/// One dismissal gesture.
enum _Gesture {
  systemBack('system back / predictive back'),
  maybePop('Navigator.maybePop'),
  tapOutside('tap outside (barrier)'),
  swipeDown('swipe down on the handle'),
  ;

  const _Gesture(this.label);

  final String label;

  Future<void> perform(WidgetTester tester, _Session s) async {
    switch (this) {
      case _Gesture.systemBack:
        await tester.binding.handlePopRoute();
      case _Gesture.maybePop:
        await Navigator.of(s.hostContext).maybePop();
      case _Gesture.tapOutside:
        await tester.tapAt(const Offset(400, 10));
      case _Gesture.swipeDown:
        await tester.fling(
          find.byKey(const ValueKey<String>('uqpay-drag-handle')),
          const Offset(0, 300),
          1200,
        );
    }
  }
}

/// A presented sheet over a host app, with a PayNow-and-card intent.
class _Session {
  _Session._(this.harness, this.hostContext);

  final SheetHarness harness;
  final BuildContext hostContext;

  static Future<_Session> start(
    WidgetTester tester, {
    bool isWeb = false,
    UqpayChallengePresenter? presenter,
    Map<String, Object?>? afterConfirm,
    Completer<UqpayHttpResponse>? heldConfirm,
  }) async {
    final harness = SheetHarness();
    Map<String, Object?> offer() =>
        intentJson()
          ..['available_payment_method_types'] = <Object?>[
            'card',
            'paynow',
          ];
    harness.http
      ..enqueue(jsonResponse(200, offer()))
      ..enqueue(jsonResponse(200, offer()));
    if (heldConfirm != null) {
      harness.http.enqueueHandler((_) => heldConfirm.future);
    } else if (afterConfirm != null) {
      harness.http.enqueue(jsonResponse(200, afterConfirm));
    }
    // Any reconcile/poll after a dismissal sees the same unfinished intent.
    for (var i = 0; i < 20; i++) {
      harness.http.enqueue(
        jsonResponse(
          200,
          afterConfirm ?? intentJson(status: 'REQUIRES_CUSTOMER_ACTION'),
        ),
      );
    }

    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    unawaited(
      UqpayPaymentSheet.present(
        captured,
        payments: harness.payments,
        intentId: kIntentId,
        returnUrl: kReturnUrl,
        clock: harness.clock,
        isWebPlatform: isWeb,
        challengePresenter: presenter,
      ).then(harness.results.add),
    );
    await pumpUntilIdle(tester, frames: 40);
    return _Session._(harness, captured);
  }

  Future<void> payWithPayNow(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-paynow')));
    await pumpUntilIdle(tester, frames: 40);
  }
}

/// The web redirect presenter as it behaves in a browser: the real
/// [UqpayRedirectChallengePresenter] persists the pending slot and starts
/// the same-tab navigation; in a browser the page then unloads, so the
/// outcome never arrives unless the flow is cancelled. `kIsWeb` is a
/// compile-time constant, so a VM test reproduces that branch here.
class _WebRedirect {
  _WebRedirect() {
    inner = UqpayRedirectChallengePresenter(
      store: store,
      launch: (url) async {
        launched.add(url);
        return true;
      },
    );
  }

  final InMemoryKeyValueStore store = InMemoryKeyValueStore();
  final List<Uri> launched = <Uri>[];
  late final UqpayRedirectChallengePresenter inner;

  UqpayChallengePresenter get presenter => _BrowserUnloadPresenter(inner);
}

class _BrowserUnloadPresenter implements UqpayChallengePresenter {
  _BrowserUnloadPresenter(this.inner);

  final UqpayChallengePresenter inner;

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    final outcome = await inner.present(request);
    if (outcome is UqpayChallengeFailed) {
      return outcome;
    }
    final cancelled = request.cancelled;
    if (cancelled == null) {
      return Completer<UqpayChallengeOutcome>().future;
    }
    await cancelled;
    return const UqpayChallengeOutcome.dismissedByUser();
  }
}
