@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sheet_harness.dart';
import 'support/sheet_screens.dart';

/// The golden matrix: **every** screen of the drop-in sheet, in
/// light and dark, at text scale 1.0 and 2.0, in LTR and RTL — 18 screens ×
/// 8 = 144 goldens under `test/goldens/sheet/`.
///
/// The pictures are taken of the real widget driven through the real flow
/// (see `support/sheet_screens.dart`), on a **320 dp** wide surface, which
/// is also how the narrow-phone layout is enforced: a `RenderFlex` overflow
/// at 320 dp × 2.0 throws, so any screen that cannot take the narrowest
/// supported phone at double text size fails this file before a golden is
/// ever compared. RTL and the host-driven brightness (the sheet never
/// forces dark mode) are visible in the same matrix.
///
/// Regenerate deliberately, never casually:
///
/// ```sh
/// flutter test --update-goldens test/sheet/sheet_goldens_test.dart
/// ```
void main() {
  // 320 dp is the narrowest width the sheet supports; the tall
  // viewport keeps the whole screen inside the captured boundary instead of
  // scrolling part of it out of the picture.
  const surface = Size(320, 1200);

  const brightnesses = <String, Brightness>{
    'light': Brightness.light,
    'dark': Brightness.dark,
  };
  const scales = <String, double>{'x1_0': 1.0, 'x2_0': 2.0};
  const directions = <String, TextDirection>{
    'ltr': TextDirection.ltr,
    'rtl': TextDirection.rtl,
  };

  for (final scenario in sheetScreenScenarios) {
    for (final brightness in brightnesses.entries) {
      for (final scale in scales.entries) {
        for (final direction in directions.entries) {
          final name =
              '${scenario.name}__${brightness.key}__${scale.key}__'
              '${direction.key}';
          testWidgets('golden: $name', (tester) async {
            tester.view.physicalSize = surface;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);

            final harness = SheetHarness();
            scenario.script(harness);
            await pumpEmbeddedSheet(
              tester,
              harness,
              isWeb: scenario.isWeb,
              challengePresenter: scenario.presenter?.call(),
              theme: ThemeData(
                colorSchemeSeed: Colors.indigo,
                brightness: brightness.value,
              ),
              textDirection: direction.value,
              textScale: scale.value,
            );
            await pumpUntilIdle(tester);
            await scenario.drive?.call(tester, harness);

            await expectLater(
              find.byKey(sheetBoundaryKey),
              matchesGoldenFile('../goldens/sheet/$name.png'),
            );
          });
        }
      }
    }
  }
}
