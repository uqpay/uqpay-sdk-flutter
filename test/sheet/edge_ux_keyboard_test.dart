import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';

/// Keyboard avoidance. With a software keyboard covering the bottom
/// of the screen, every card-form field the customer moves to is scrolled
/// into the visible area; "next" walks the fields in a sensible order; an
/// external keyboard's Tab does the same; and the sheet does not jump.
void main() {
  const fieldOrder = <String>[
    'uqpay-card-number',
    'uqpay-card-expiry',
    'uqpay-card-cvc',
    'uqpay-card-name',
    'uqpay-card-email',
    'uqpay-card-street',
    'uqpay-card-city',
    'uqpay-card-state',
    'uqpay-card-postcode',
  ];

  const keyboard = 300.0;

  for (final presented in <bool>[true, false]) {
    final mode = presented ? 'presented' : 'embedded';
    for (final screen in <(String, Size, double)>[
      ('phone 400x800, scale 1.0', const Size(400, 800), 1),
      ('phone 400x800, scale 2.0', const Size(400, 800), 2),
      ('small 360x640, scale 1.0', const Size(360, 640), 1),
      ('small 360x640, scale 2.0', const Size(360, 640), 2),
    ]) {
      testWidgets(
        '$mode, ${screen.$1}: "next" walks every field in order and each '
        'focused field is above a ${keyboard.toInt()}dp keyboard',
        (tester) async {
          await _pumpCardForm(
            tester,
            size: screen.$2,
            textScale: screen.$3,
            keyboardInset: keyboard,
            presented: presented,
          );
          final visibleBottom = screen.$2.height - keyboard;

          await tester.showKeyboard(
            find.byKey(ValueKey<String>(fieldOrder[0])),
          );
          await tester.pumpAndSettle();
          double? sheetTop;
          for (var i = 0; i < fieldOrder.length; i++) {
            final key = fieldOrder[i];
            if (i > 0) {
              await tester.testTextInput.receiveAction(TextInputAction.next);
              await tester.pumpAndSettle();
            }
            _expectFocused(tester, key);
            _expectVisible(tester, key, visibleBottom);
            if (presented) {
              // The presented sheet stays put; only its content scrolls.
              // (An embedded sheet scrolls with the host's own scroll view,
              // which is the host's layout, not the sheet's.)
              final top = tester
                  .getRect(
                    find.byKey(const ValueKey<String>('uqpay-drag-handle')),
                  )
                  .top;
              sheetTop ??= top;
              expect(top, sheetTop, reason: 'the sheet jumped focusing $key');
            }
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('focusing a field directly (tap-to-focus order reversed) '
      'still scrolls it above the keyboard — small screen, scale 2.0', (
    tester,
  ) async {
    await _pumpCardForm(
      tester,
      size: const Size(360, 640),
      textScale: 2,
      keyboardInset: keyboard,
      presented: true,
    );
    for (final key in fieldOrder.reversed) {
      await tester.showKeyboard(find.byKey(ValueKey<String>(key)));
      await tester.pumpAndSettle();
      _expectFocused(tester, key);
      _expectVisible(tester, key, 640 - keyboard);
    }
  });

  // The order a real device uses: the field takes focus first, then the
  // engine reports the keyboard through the view's insets frame by frame as
  // it animates in; EditableText re-scrolls in didChangeMetrics.
  for (final presented in <bool>[true, false]) {
    testWidgets(
      '${presented ? 'presented' : 'embedded'}: a keyboard animating in after '
      'the bottom field took focus leaves that field visible',
      (tester) async {
        await _pumpCardForm(
          tester,
          size: const Size(360, 640),
          textScale: 1,
          keyboardInset: 0,
          presented: presented,
        );
        const key = 'uqpay-card-postcode';
        await tester.showKeyboard(find.byKey(const ValueKey<String>(key)));
        await tester.pumpAndSettle();
        _expectVisible(tester, key, 640);

        for (var step = 1; step <= 10; step++) {
          tester.view.viewInsets = FakeViewPadding(
            bottom: keyboard * step / 10,
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();

        _expectFocused(tester, key);
        _expectVisible(tester, key, 640 - keyboard);
      },
      // Regression: the presented frame once applied the inset through a
      // 100 ms AnimatedPadding, so the post-frame scroll-into-view measured
      // the not-yet-shrunk viewport and the field ended up behind the
      // keyboard (postcode at y=367..423 with the keyboard top at 340).
    );
  }

  testWidgets('external keyboard: Tab walks the same order and keeps each '
      'field on screen (no software inset)', (tester) async {
    await _pumpCardForm(
      tester,
      size: const Size(360, 640),
      textScale: 1,
      keyboardInset: 0,
      presented: true,
    );
    await tester.showKeyboard(find.byKey(ValueKey<String>(fieldOrder[0])));
    await tester.pumpAndSettle();
    for (var i = 1; i < fieldOrder.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      _expectFocused(tester, fieldOrder[i]);
      _expectVisible(tester, fieldOrder[i], 640);
    }
  });
}

/// Opens the card form on a [size] screen with a software keyboard of
/// [keyboardInset] reported through MediaQuery (0 leaves the view's own
/// insets untouched).
Future<void> _pumpCardForm(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  required double keyboardInset,
  required bool presented,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  final harness = SheetHarness();
  harness.http.enqueue(jsonResponse(200, intentJson()));

  final Widget home = presented
      ? Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                key: const ValueKey<String>('open-sheet'),
                onPressed: () => unawaited(
                  UqpayPaymentSheet.present(
                    context,
                    payments: harness.payments,
                    intentId: kIntentId,
                    returnUrl: kReturnUrl,
                    clock: harness.clock,
                    isWebPlatform: false,
                  ).then(harness.results.add),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        )
      : Scaffold(
          body: SingleChildScrollView(
            child: UqpayPaymentSheet(
              key: const ValueKey<String>('embedded-sheet'),
              payments: harness.payments,
              intentId: kIntentId,
              returnUrl: kReturnUrl,
              clock: harness.clock,
              isWebPlatform: false,
              onResult: harness.results.add,
            ),
          ),
        );

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: keyboardInset == 0
                ? media.viewInsets
                : EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        );
      },
      home: home,
    ),
  );
  await tester.pumpAndSettle();
  if (presented) {
    await tester.tap(find.byKey(const ValueKey<String>('open-sheet')));
    await tester.pumpAndSettle();
  }
  final card = find.byKey(const ValueKey<String>('uqpay-method-card'));
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  await tester.tap(card);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey<String>('uqpay-card-number')), findsOne);
}

void _expectFocused(WidgetTester tester, String key) {
  final focused = FocusManager.instance.primaryFocus?.context;
  expect(focused, isNotNull, reason: 'nothing has focus; expected $key');
  final field = tester.element(find.byKey(ValueKey<String>(key)));
  var inside = false;
  focused!.visitAncestorElements((e) {
    if (identical(e, field)) {
      inside = true;
      return false;
    }
    return true;
  });
  expect(inside, isTrue, reason: '$key should hold focus');
}

/// The whole field — label, input line and any error line — sits between
/// the top of the screen and the top of the keyboard.
void _expectVisible(WidgetTester tester, String key, double visibleBottom) {
  final rect = tester.getRect(find.byKey(ValueKey<String>(key)));
  expect(
    rect.top,
    greaterThanOrEqualTo(0),
    reason: '$key is scrolled off the top: $rect',
  );
  expect(
    rect.bottom,
    lessThanOrEqualTo(visibleBottom + 0.5),
    reason:
        '$key is hidden behind the keyboard (visible to $visibleBottom): '
        '$rect',
  );
}
