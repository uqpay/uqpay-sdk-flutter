import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';
import 'support/sheet_screens.dart';

/// Every screen passes Flutter's accessibility guidelines — tap
/// targets ≥ 48×48 dp, text contrast ≥ 4.5:1 and a label on every tappable
/// node — and failures are announced to the screen reader.
///
/// The guideline checks are the automated half of the accessibility
/// requirement; the other half is a manual TalkBack/VoiceOver pass.
void main() {
  const l10n = UqpayLocalizations();

  for (final scenario in sheetScreenScenarios) {
    testWidgets('screen "${scenario.name}" meets the accessibility '
        'guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      // A narrow phone: the tightest layout the sheet supports, so tap
      // targets are measured where they are most likely to be squeezed.
      tester.view.physicalSize = const Size(360, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

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

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }

  testWidgets('the sheet title is a semantic header and the close control '
      'is labelled', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = SheetHarness();
    harness.http.enqueue(jsonResponse(200, intentJson()));
    await pumpEmbeddedSheet(tester, harness);
    await pumpUntilIdle(tester);

    expect(
      tester.getSemantics(find.text(l10n.paySheetTitle)),
      matchesSemantics(label: l10n.paySheetTitle, isHeader: true),
    );
    // The close affordance's accessible name reaches TalkBack/VoiceOver as
    // the button's tooltip — `labeledTapTargetGuideline` above accepts it,
    // and this pins the actual string.
    expect(
      tester
          .getSemantics(
            find
                .descendant(
                  of: find.byKey(
                    const ValueKey<String>('uqpay-close-button'),
                  ),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .tooltip,
      l10n.close,
    );
    handle.dispose();
  });

  group('screen-reader announcements', () {
    /// Records what the framework sends on the accessibility channel.
    List<String> announcementsOf(WidgetTester tester) {
      final messages = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            message,
          ) async {
            final map = message as Map<Object?, Object?>;
            if (map['type'] == 'announce') {
              final data = map['data']! as Map<Object?, Object?>;
              messages.add(data['message']! as String);
            }
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      return messages;
    }

    testWidgets('a load failure is announced', (tester) async {
      final harness = SheetHarness();
      final announced = announcementsOf(tester);
      harness.http.enqueue(
        jsonResponse(500, <String, Object?>{
          'code': 'internal_error',
          'type': 'api_error',
          'message': '',
        }),
      );
      await pumpEmbeddedSheet(tester, harness);
      await pumpUntilIdle(tester);

      expect(announced, isNotEmpty);
    });

    testWidgets('a declined payment is announced', (tester) async {
      final harness = SheetHarness();
      final announced = announcementsOf(tester);
      final scenario = sheetScreenScenarios.firstWhere(
        (s) => s.name == 'result_failed',
      );
      scenario.script(harness);
      await pumpEmbeddedSheet(tester, harness);
      await pumpUntilIdle(tester);
      await scenario.drive!(tester, harness);

      expect(find.text(l10n.failedTitle), findsOneWidget);
      expect(announced, isNotEmpty);
    });

    testWidgets('an invalid card field is announced when pay is tapped', (
      tester,
    ) async {
      final harness = SheetHarness();
      final announced = announcementsOf(tester);
      final scenario = sheetScreenScenarios.firstWhere(
        (s) => s.name == 'card_form_invalid',
      );
      scenario.script(harness);
      await pumpEmbeddedSheet(tester, harness);
      await pumpUntilIdle(tester);
      await scenario.drive!(tester, harness);

      expect(announced, contains(l10n.errorInvalidCardNumber));
      expect(harness.confirms, isEmpty);
    });
  });
}
