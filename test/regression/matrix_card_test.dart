import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../sheet/support/sheet_harness.dart';
import '../support/fakes.dart';

/// Failure matrix, card column: the cells the existing suites did not name
/// a test for. The full matrix (with the existing test cited per cell) is in
/// `doc/testing.md`, "Scenario coverage".
void main() {
  const l10n = UqpayLocalizations();

  /// Answers every request with the intent in whatever status [status]
  /// currently returns, so a test can change the server's mind mid-flow.
  void serveLive(SheetHarness harness, String Function() status, {int n = 40}) {
    for (var i = 0; i < n; i++) {
      harness.http.enqueueHandler(
        (_) => jsonResponse(200, intentJson(status: status())),
      );
    }
  }

  Future<void> openCardForm(WidgetTester tester, SheetHarness harness) async {
    harness.http.enqueue(jsonResponse(200, intentJson()));
    await pumpEmbeddedSheet(tester, harness);
    await pumpUntilIdle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
    await pumpUntilIdle(tester);
  }

  group('failure matrix, card: sheet dismiss', () {
    testWidgets('closing the presented sheet on the card form, before Pay, '
        'resolves Canceled(userDismissed) and sends no confirm', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, intentJson()));
      final future = await presentSheet(tester, harness);
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await pumpUntilIdle(tester, frames: 20);
      expect(
        find.byKey(const ValueKey<String>('uqpay-card-number')),
        findsOneWidget,
      );

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
  });

  group('failure matrix, card: dismiss-mid-confirm', () {
    testWidgets('closing the sheet while a card payment awaits its outcome '
        'resolves Pending, never Canceled', (tester) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester);
      harness.http.enqueue(jsonResponse(200, intentJson())); // guard
      serveLive(harness, () => 'PENDING');
      await tapPay(tester);
      await pumpUntilIdle(tester);
      expect(harness.confirms, hasLength(1));
      expect(find.text(l10n.awaitingOutcomeTitle), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      await pumpUntilIdle(tester);

      final result = harness.results.single;
      expect(result, isA<UqpayPaymentPending>());
      expect(
        (result as UqpayPaymentPending).lastKnownStatus,
        UqpayIntentStatus.pending,
      );
    });
  });

  group('failure matrix, card: app backgrounded mid-flow', () {
    testWidgets('a card payment backgrounded while awaiting its outcome sends '
        'nothing while paused and resolves from the server on resume', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester);
      harness.http.enqueue(jsonResponse(200, intentJson())); // guard
      var status = 'PENDING';
      serveLive(harness, () => status);
      await tapPay(tester);
      await pumpUntilIdle(tester);
      expect(find.text(l10n.awaitingOutcomeTitle), findsOneWidget);

      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpUntilIdle(tester);
      final readsWhilePaused = harness.reads.length;
      // The customer finishes paying elsewhere while the app is away.
      status = 'SUCCEEDED';
      harness.clock.advance(const Duration(minutes: 5));
      await pumpUntilIdle(tester);
      expect(harness.reads, hasLength(readsWhilePaused));
      expect(harness.results, isEmpty);

      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntilIdle(tester);

      expect(harness.reads.length, greaterThan(readsWhilePaused));
      expect(find.text(l10n.successTitle), findsOneWidget);
      expect(harness.confirms, hasLength(1), reason: 'never re-confirmed');
      await tester.tap(find.text(l10n.done));
      await pumpUntilIdle(tester);
      expect(harness.results.single, isA<UqpayPaymentCompleted>());
    });
  });

  group('failure matrix, card: 3-D Secure through the sheet', () {
    UqpayHttpResponse rca() => jsonResponse(
      200,
      intentJson(
        status: 'REQUIRES_CUSTOMER_ACTION',
        nextAction: redirectNextAction(),
      ),
    );

    testWidgets('3DS pass: the challenge returns, the server says SUCCEEDED, '
        'the sheet shows success and delivers Completed', (tester) async {
      final harness = SheetHarness();
      final presenter = RecordingPresenter(
        UqpayChallengeOutcome.returned(kReturnUrl),
      );
      harness.http.enqueue(jsonResponse(200, intentJson()));
      await pumpEmbeddedSheet(
        tester,
        harness,
        challengePresenter: presenter,
      );
      await pumpUntilIdle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await pumpUntilIdle(tester);
      await fillValidCard(tester);
      harness.http
        ..enqueue(jsonResponse(200, intentJson())) // guard
        ..enqueue(rca()) // confirm
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tapPay(tester);
      await pumpUntilIdle(tester);

      expect(presenter.requests, hasLength(1));
      expect(find.text(l10n.successTitle), findsOneWidget);
      await tester.tap(find.text(l10n.done));
      await pumpUntilIdle(tester);
      expect(harness.results.single, isA<UqpayPaymentCompleted>());
    });

    testWidgets('3DS fail: the challenge returns, the server reports '
        '3ds_failed, the sheet delivers Failed(threeDsFailed)', (
      tester,
    ) async {
      final harness = SheetHarness();
      final presenter = RecordingPresenter(
        UqpayChallengeOutcome.returned(kReturnUrl),
      );
      harness.http.enqueue(jsonResponse(200, intentJson()));
      await pumpEmbeddedSheet(
        tester,
        harness,
        challengePresenter: presenter,
      );
      await pumpUntilIdle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await pumpUntilIdle(tester);
      await fillValidCard(tester);
      final failed = jsonResponse(
        200,
        intentJson(attempt: failedAttempt('3ds_failed')),
      );
      harness.http
        ..enqueue(jsonResponse(200, intentJson())) // guard
        ..enqueue(rca()) // confirm
        ..enqueue(failed)
        ..enqueue(failed);
      await tapPay(tester);
      await pumpUntilIdle(tester);

      expect(presenter.requests, hasLength(1));
      expect(find.text(l10n.failedTitle), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      await pumpUntilIdle(tester);
      final result = harness.results.single;
      expect(result, isA<UqpayPaymentFailed>());
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.threeDsFailed,
      );
    });
  });
}
