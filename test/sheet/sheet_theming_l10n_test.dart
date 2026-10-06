import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';

/// Theming and the string catalogue.
void main() {
  const l10n = UqpayLocalizations();
  final light = ThemeData(colorSchemeSeed: Colors.indigo);
  final dark = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.dark,
  );

  group('UqpayAppearance', () {
    test('the default appearance changes nothing, brightness least of all', () {
      const appearance = UqpayAppearance();
      expect(appearance.themeFor(light), same(light));
      expect(appearance.themeFor(dark), same(dark));
      // The iOS SDK force-locked dark mode; this one
      // follows the host in both directions.
      expect(appearance.themeFor(dark).brightness, Brightness.dark);
      expect(appearance.themeFor(light).brightness, Brightness.light);
    });

    test('a colour scheme override replaces the scheme only', () {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      final theme = UqpayAppearance(colorScheme: scheme).themeFor(light);
      expect(theme.colorScheme, scheme);
      expect(theme.textTheme, light.textTheme);
    });

    test('a text theme override replaces the text theme only', () {
      const text = TextTheme(bodyMedium: TextStyle(fontSize: 42));
      final theme = const UqpayAppearance(textTheme: text).themeFor(light);
      expect(theme.textTheme.bodyMedium?.fontSize, 42);
      expect(theme.colorScheme, light.colorScheme);
    });

    test('a corner radius reaches fields, buttons and cards', () {
      final theme = const UqpayAppearance(cornerRadius: 4).themeFor(light);
      final border = theme.inputDecorationTheme.border! as OutlineInputBorder;
      expect(border.borderRadius, BorderRadius.circular(4));
      expect(
        theme.filledButtonTheme.style?.shape?.resolve(<WidgetState>{}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      expect(
        theme.outlinedButtonTheme.style?.shape?.resolve(<WidgetState>{}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      expect(
        theme.cardTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
    });

    test('a pay-button style replaces the filled-button theme', () {
      final style = FilledButton.styleFrom(backgroundColor: Colors.pink);
      final theme = UqpayAppearance(payButtonStyle: style).themeFor(light);
      expect(theme.filledButtonTheme.style, style);
    });

    test('value equality and hashCode', () {
      const a = UqpayAppearance(cornerRadius: 8);
      const b = UqpayAppearance(cornerRadius: 8);
      const c = UqpayAppearance(cornerRadius: 12);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(const UqpayAppearance()));
      expect(a == Object(), isFalse);
    });

    testWidgets('the sheet renders with the host brightness and the '
        'appearance overrides applied', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, intentJson()));
      await tester.pumpWidget(
        MaterialApp(
          theme: dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: UqpayPaymentSheet(
                payments: harness.payments,
                intentId: kIntentId,
                returnUrl: kReturnUrl,
                clock: harness.clock,
                isWebPlatform: false,
                appearance: UqpayAppearance(
                  cornerRadius: 2,
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.teal,
                    brightness: Brightness.dark,
                  ),
                ),
                onResult: harness.results.add,
              ),
            ),
          ),
        ),
      );
      await pumpUntilIdle(tester);

      final sheetTheme = Theme.of(
        tester.element(find.text(l10n.chooseMethodTitle)),
      );
      expect(sheetTheme.brightness, Brightness.dark);
      expect(sheetTheme.colorScheme.primary, isNot(dark.colorScheme.primary));
    });
  });

  group('UqpayLocalizations', () {
    testWidgets('resolves without any localisation setup', (tester) async {
      late UqpayLocalizations resolved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = UqpayLocalizations.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved.paySheetTitle, l10n.paySheetTitle);
    });

    testWidgets('resolves through the shipped delegate', (tester) async {
      late UqpayLocalizations resolved;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const <LocalizationsDelegate<Object?>>[
            UqpayLocalizations.delegate,
          ],
          locale: const Locale('de'),
          home: Builder(
            builder: (context) {
              resolved = UqpayLocalizations.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved, isA<UqpayLocalizations>());
      expect(resolved.done, l10n.done);
    });

    test('the delegate supports every locale and never reloads', () {
      const delegate = UqpayLocalizations.delegate;
      expect(delegate.isSupported(const Locale('ar')), isTrue);
      expect(delegate.isSupported(const Locale('zh', 'HK')), isTrue);
      expect(delegate.shouldReload(delegate), isFalse);
    });

    test('every renderable method type has a display name', () {
      const types = <String>[
        'card',
        'wechatpay',
        'alipaycn',
        'alipayhk',
        'grabpay',
        'paynow',
        'unionpay',
        'truemoney',
        'tng',
        'gcash',
        'dana',
        'kakaopay',
        'tosspay',
        'naverpay',
      ];
      for (final type in types) {
        final name = l10n.methodDisplayName(type);
        expect(name, isNotEmpty);
        expect(
          name,
          isNot(type),
          reason: '$type must have a human display name',
        );
      }
      // An unknown type degrades to the raw wire value rather than crashing.
      expect(l10n.methodDisplayName('space_credits'), 'space_credits');
    });

    test('interpolated strings carry their argument', () {
      expect(l10n.payAmount(r'$8.98'), contains(r'$8.98'));
      expect(l10n.qrInstruction('PayNow'), contains('PayNow'));
      expect(l10n.qrExpiresIn('9:59'), contains('9:59'));
    });

    test('every string in the catalogue is non-empty', () {
      final strings = <String>[
        l10n.paySheetTitle,
        l10n.close,
        l10n.cancel,
        l10n.retry,
        l10n.done,
        l10n.dismissBarrierLabel,
        l10n.dragHandleLabel,
        l10n.loadingPayment,
        l10n.loadFailedTitle,
        l10n.noMethodsTitle,
        l10n.noMethodsBody,
        l10n.webCardUnavailableNotice,
        l10n.webCardOnlyBody,
        l10n.chooseMethodTitle,
        l10n.cardDetailsTitle,
        l10n.cardNumberLabel,
        l10n.expiryLabel,
        l10n.expiryHint,
        l10n.securityCodeLabel,
        l10n.cardholderNameLabel,
        l10n.errorInvalidCardNumber,
        l10n.errorInvalidExpiry,
        l10n.errorCardExpired,
        l10n.errorInvalidSecurityCode,
        l10n.errorNameRequired,
        l10n.processingTitle,
        l10n.processingBody,
        l10n.cannotCloseWhileProcessing,
        l10n.verifyingTitle,
        l10n.verifyingBody,
        l10n.awaitingOutcomeTitle,
        l10n.awaitingOutcomeBody,
        l10n.qrExpiredTitle,
        l10n.qrExpiredBody,
        l10n.qrCodeSemanticLabel,
        l10n.qrImageLoadFailed,
        l10n.bankDetailsTitle,
        l10n.bankDetailsBody,
        l10n.bankNameLabel,
        l10n.accountNumberLabel,
        l10n.routingNumberLabel,
        l10n.successTitle,
        l10n.successBody,
        l10n.pendingTitle,
        l10n.pendingBody,
        l10n.failedTitle,
        l10n.canceledTitle,
        l10n.canceledBody,
        l10n.verificationTitle,
      ];
      expect(strings.where((s) => s.trim().isEmpty), isEmpty);
    });
  });
}
