import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import 'support/sheet_harness.dart';
import 'support/sheet_screens.dart';

/// Proves every scripted scenario in [sheetScreenScenarios] really reaches
/// the screen it claims to (every asynchronous state is a screen).
///
/// The golden matrix and the accessibility guideline tests replay the same
/// scenarios, so a mis-scripted scenario fails **here**, with a readable
/// message, instead of silently baking a wrong picture into a golden.
void main() {
  const l10n = UqpayLocalizations();

  /// The text that must be on screen once the scenario has been driven.
  final markers = <String, String>{
    'loading': l10n.loadingPayment,
    'load_failed': l10n.loadFailedTitle,
    'no_methods': l10n.noMethodsTitle,
    'method_list': l10n.chooseMethodTitle,
    'method_list_web': l10n.webCardUnavailableNotice,
    'web_card_only': l10n.webCardOnlyBody,
    'card_form': l10n.cardDetailsTitle,
    'card_form_invalid': l10n.errorInvalidCardNumber,
    'processing': l10n.processingTitle,
    'awaiting_outcome': l10n.awaitingOutcomeTitle,
    'verifying': l10n.verifyingTitle,
    'qr': l10n.qrInstruction(l10n.methodDisplayName('paynow')),
    'bank_details': l10n.bankDetailsTitle,
    'result_success': l10n.successTitle,
    'result_canceled': l10n.canceledTitle,
    'result_failed': l10n.failedTitle,
    'result_pending': l10n.pendingTitle,
    'result_qr_expired': l10n.qrExpiredTitle,
  };

  test('every screen scenario has a marker and a unique name', () {
    final names = sheetScreenScenarios.map((s) => s.name).toList();
    expect(names.toSet(), hasLength(names.length));
    expect(markers.keys.toSet(), names.toSet());
  });

  for (final scenario in sheetScreenScenarios) {
    testWidgets('scenario "${scenario.name}" reaches its screen', (
      tester,
    ) async {
      final harness = SheetHarness();
      scenario.script(harness);
      await pumpEmbeddedSheet(
        tester,
        harness,
        isWeb: scenario.isWeb,
        challengePresenter: scenario.presenter?.call(),
      );
      await pumpUntilIdle(tester);
      await scenario.drive?.call(tester, harness);

      expect(
        find.text(markers[scenario.name]!),
        findsOneWidget,
        reason: 'scenario ${scenario.name} did not reach its screen',
      );
      // No screen is a dead end: something is always tappable, or the flow
      // is still working and says so.
      expect(find.byType(UqpayPaymentSheet), findsOneWidget);
    });
  }

  testWidgets('the QR screen renders the server payload with a countdown '
      'and never claims success on its own', (tester) async {
    final scenario = sheetScreenScenarios.firstWhere((s) => s.name == 'qr');
    final harness = SheetHarness();
    scenario.script(harness);
    await pumpEmbeddedSheet(tester, harness);
    await pumpUntilIdle(tester);
    await scenario.drive!(tester, harness);

    expect(
      find.byKey(const ValueKey<String>('uqpay-qr-countdown')),
      findsOneWidget,
    );
    expect(find.text(l10n.qrExpiresIn('10:00')), findsOneWidget);
    expect(find.text(l10n.successTitle), findsNothing);

    // One second of clock time, one second off the countdown.
    harness.clock.advance(const Duration(seconds: 1));
    await pumpUntilIdle(tester);
    expect(find.text(l10n.qrExpiresIn('9:59')), findsOneWidget);
    expect(harness.results, isEmpty);
  });
}
