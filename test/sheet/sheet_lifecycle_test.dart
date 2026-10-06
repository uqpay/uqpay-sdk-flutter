import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';
import 'support/sheet_screens.dart';

/// `UqpayPaymentSheet.present` end to end: result delivery,
/// the one dismissal path and its semantics, the
/// mid-confirm lock, the second-present guard, background
/// pausing and the leak check.
void main() {
  const l10n = UqpayLocalizations();

  /// Pumps a host app and returns a context the test can present from —
  /// including while a sheet is already up, which no tap could reach.
  Future<BuildContext> pumpHost(WidgetTester tester) async {
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
    return captured;
  }

  Future<UqpayPaymentResult> present(
    BuildContext context,
    SheetHarness harness, {
    UqpayChallengePresenter? challengePresenter,
  }) {
    final future = UqpayPaymentSheet.present(
      context,
      payments: harness.payments,
      intentId: kIntentId,
      returnUrl: kReturnUrl,
      clock: harness.clock,
      isWebPlatform: false,
      challengePresenter: challengePresenter,
    );
    unawaited(future.then(harness.results.add));
    return future;
  }

  testWidgets('present resolves once, after the sheet has finished closing', (
    tester,
  ) async {
    final harness = SheetHarness();
    harness.http
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    final context = await pumpHost(tester);
    final future = present(context, harness);
    await pumpUntilIdle(tester, frames: 40);

    expect(find.text(l10n.successTitle), findsOneWidget);
    await tester.tap(find.text(l10n.done));
    await pumpUntilIdle(tester, frames: 40);

    expect(await future, isA<UqpayPaymentCompleted>());
    expect(harness.results, hasLength(1));
    // The route is fully gone before the future resolves, so the merchant
    // may navigate or setState straight away.
    expect(find.byType(UqpayPaymentSheet), findsNothing);
  });

  group('second-present guard', () {
    testWidgets('a second present for the same intent returns Failed and '
        'opens no second sheet', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, intentJson()));
      final context = await pumpHost(tester);
      final first = present(context, harness);
      await pumpUntilIdle(tester, frames: 40);
      expect(find.text(l10n.chooseMethodTitle), findsOneWidget);

      final second = await present(context, harness);
      await pumpUntilIdle(tester);

      expect(second, isA<UqpayPaymentFailed>());
      expect(
        (second as UqpayPaymentFailed).error.code,
        UqpayErrorCode.invalidConfiguration,
      );
      expect(second.error.isRetryable, isFalse);
      expect(find.byType(UqpayPaymentSheet), findsOneWidget);
      expect(harness.reads, hasLength(1), reason: 'no second load');

      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      await pumpUntilIdle(tester, frames: 40);
      expect(await first, isA<UqpayPaymentCanceled>());
    });

    testWidgets('the guard releases the intent once the first sheet has '
        'closed', (tester) async {
      final harness = SheetHarness();
      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson()));
      final context = await pumpHost(tester);
      final first = present(context, harness);
      await pumpUntilIdle(tester, frames: 40);
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      await pumpUntilIdle(tester, frames: 40);
      expect(await first, isA<UqpayPaymentCanceled>());

      final second = present(context, harness);
      await pumpUntilIdle(tester, frames: 40);
      expect(find.text(l10n.chooseMethodTitle), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      await pumpUntilIdle(tester, frames: 40);
      expect(await second, isA<UqpayPaymentCanceled>());
    });
  });

  group(
    'one dismissal path with Canceled-before / Pending-after semantics',
    () {
      testWidgets('system back before any confirm resolves Canceled', (
        tester,
      ) async {
        final harness = SheetHarness();
        harness.http.enqueue(jsonResponse(200, intentJson()));
        final context = await pumpHost(tester);
        final future = present(context, harness);
        await pumpUntilIdle(tester, frames: 40);

        await tester.binding.handlePopRoute();
        await pumpUntilIdle(tester, frames: 40);

        final result = await future;
        expect(result, isA<UqpayPaymentCanceled>());
        expect(
          (result as UqpayPaymentCanceled).reason,
          UqpayCancelReason.userDismissed,
        );
        expect(harness.confirms, isEmpty);
      });

      testWidgets('a tap outside the sheet resolves through the same path', (
        tester,
      ) async {
        final harness = SheetHarness();
        harness.http.enqueue(jsonResponse(200, intentJson()));
        final context = await pumpHost(tester);
        final future = present(context, harness);
        await pumpUntilIdle(tester, frames: 40);

        await tester.tapAt(const Offset(400, 20));
        await pumpUntilIdle(tester, frames: 40);

        expect(await future, isA<UqpayPaymentCanceled>());
      });

      testWidgets('a swipe down on the drag handle resolves through the same '
          'path', (tester) async {
        final harness = SheetHarness();
        harness.http.enqueue(jsonResponse(200, intentJson()));
        final context = await pumpHost(tester);
        final future = present(context, harness);
        await pumpUntilIdle(tester, frames: 40);

        await tester.fling(
          find.byKey(const ValueKey<String>('uqpay-drag-handle')),
          const Offset(0, 300),
          1200,
        );
        await pumpUntilIdle(tester, frames: 40);

        expect(await future, isA<UqpayPaymentCanceled>());
      });

      testWidgets('dismissing after the confirm has left resolves Pending, '
          'never Canceled', (tester) async {
        final harness = SheetHarness();
        final scenario = sheetScreenScenarios.firstWhere((s) => s.name == 'qr');
        scenario.script(harness);
        final context = await pumpHost(tester);
        final future = present(context, harness);
        await pumpUntilIdle(tester, frames: 40);
        await tester.tap(
          find.byKey(const ValueKey<String>('uqpay-method-paynow')),
        );
        await pumpUntilIdle(tester, frames: 40);
        expect(harness.confirms, hasLength(1));

        await tester.tap(find.text(l10n.cancel));
        await pumpUntilIdle(tester, frames: 40);

        expect(
          await future,
          isA<UqpayPaymentPending>(),
          reason: 'the confirm has left the device — cancelling is a lie',
        );
      });

      testWidgets('the sheet refuses to close while a confirm is in flight', (
        tester,
      ) async {
        final harness = SheetHarness();
        final scenario = sheetScreenScenarios.firstWhere(
          (s) => s.name == 'processing',
        );
        scenario.script(harness);
        final context = await pumpHost(tester);
        final future = present(context, harness);
        await pumpUntilIdle(tester, frames: 40);
        await tester.tap(
          find.byKey(const ValueKey<String>('uqpay-method-paynow')),
        );
        await pumpUntilIdle(tester, frames: 40);
        expect(find.text(l10n.processingTitle), findsOneWidget);

        // Back, barrier tap and the close button are all refused.
        await tester.binding.handlePopRoute();
        await pumpUntilIdle(tester, frames: 20);
        await tester.tapAt(const Offset(400, 20));
        await pumpUntilIdle(tester, frames: 20);
        await tester.tap(
          find.byKey(const ValueKey<String>('uqpay-close-button')),
        );
        await pumpUntilIdle(tester, frames: 20);

        expect(find.text(l10n.processingTitle), findsOneWidget);
        expect(harness.results, isEmpty);
        // The screen states why it cannot be closed.
        expect(find.text(l10n.processingBody), findsOneWidget);
        unawaited(future);
      });
    },
  );

  testWidgets('backgrounding pauses the flow and resuming reconciles', (
    tester,
  ) async {
    final harness = SheetHarness();
    final scenario = sheetScreenScenarios.firstWhere(
      (s) => s.name == 'awaiting_outcome',
    );
    scenario.script(harness);
    for (var i = 0; i < 8; i++) {
      harness.http.enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
    }
    await pumpEmbeddedSheet(tester, harness);
    await pumpUntilIdle(tester);
    await scenario.drive!(tester, harness);
    expect(find.text(l10n.awaitingOutcomeTitle), findsOneWidget);

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await pumpUntilIdle(tester);
    final readsWhilePaused = harness.reads.length;
    harness.clock.advance(const Duration(minutes: 2));
    await pumpUntilIdle(tester);
    expect(
      harness.reads,
      hasLength(readsWhilePaused),
      reason: 'a backgrounded sheet sends nothing',
    );

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntilIdle(tester);
    expect(
      harness.reads.length,
      greaterThan(readsWhilePaused),
      reason: 'resuming reconciles with the server before showing anything',
    );
  });

  group('leak check', () {
    testWidgets('a closed sheet leaves no live timer, no open subscription '
        'and no widget tree behind', (tester) async {
      final harness = SheetHarness();
      final scenario = sheetScreenScenarios.firstWhere((s) => s.name == 'qr');
      scenario.script(harness);
      final context = await pumpHost(tester);
      final future = present(context, harness);
      await pumpUntilIdle(tester, frames: 40);
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-method-paynow')),
      );
      await pumpUntilIdle(tester, frames: 40);

      // While the QR is up the sheet legitimately holds live timers: the
      // countdown and the poll schedule.
      expect(find.text(l10n.qrExpiresIn('10:00')), findsOneWidget);
      expect(harness.clock.pendingTimers, greaterThan(0));

      await tester.tap(find.text(l10n.cancel));
      await pumpUntilIdle(tester, frames: 40);
      await future;

      expect(
        harness.clock.pendingTimers,
        0,
        reason: 'every countdown and poll timer must be cancelled on close',
      );
      expect(
        harness.flows.every((f) => f.isDone),
        isTrue,
        reason:
            'a finished flow has closed its status stream, so the '
            "sheet's subscription is gone",
      );
      expect(find.byType(UqpayPaymentSheet), findsNothing);

      // And nothing wakes back up: half an hour later, not one more request.
      final requestsAtClose = harness.http.requests.length;
      for (var i = 0; i < 30; i++) {
        harness.clock.advance(const Duration(minutes: 1));
        await pumpUntilIdle(tester, frames: 2);
      }
      expect(harness.http.requests, hasLength(requestsAtClose));
    });

    testWidgets('an embedded sheet removed from the tree calls its payment '
        'off instead of leaking it', (tester) async {
      final harness = SheetHarness();
      final scenario = sheetScreenScenarios.firstWhere((s) => s.name == 'qr');
      scenario.script(harness);
      await pumpEmbeddedSheet(tester, harness);
      await pumpUntilIdle(tester);
      await scenario.drive!(tester, harness);
      expect(harness.clock.pendingTimers, greaterThan(0));

      // The host navigates away with the payment still running.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await pumpUntilIdle(tester);

      expect(harness.clock.pendingTimers, 0);
      expect(harness.flows.every((f) => f.isDone), isTrue);

      final requestsAtClose = harness.http.requests.length;
      harness.clock.advance(const Duration(minutes: 30));
      await pumpUntilIdle(tester);
      expect(harness.http.requests, hasLength(requestsAtClose));
    });
  });
}
