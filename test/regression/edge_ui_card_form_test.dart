import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_formatters.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/card_form_view.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../sheet/support/sheet_harness.dart';
import '../support/fakes.dart';

/// Card-form edge-case regressions: per-field validation, screen-reader
/// announcements, billing state, LTR fields in RTL, keyboard actions, the
/// expiry formatter, Unicode digits and the 128-character name cap.
void main() {
  const l10n = UqpayLocalizations();

  /// Every validation message the form can show.
  final allErrors = <String>[
    l10n.errorInvalidCardNumber,
    l10n.errorInvalidExpiry,
    l10n.errorCardExpired,
    l10n.errorInvalidSecurityCode,
    l10n.errorNameRequired,
    l10n.errorNameTooLong,
    l10n.errorInvalidEmail,
    l10n.errorStreetRequired,
    l10n.errorCityRequired,
    l10n.errorStateRequired,
    l10n.errorPostcodeRequired,
    l10n.errorCountryRequired,
  ];

  int visibleErrors() =>
      allErrors.where((e) => find.text(e).evaluate().isNotEmpty).length;

  Finder field(String name) => find.byKey(ValueKey<String>('uqpay-card-$name'));

  Future<void> openCardForm(
    WidgetTester tester,
    SheetHarness harness, {
    UqpayBillingDetails? billingDetails,
  }) async {
    harness.http.enqueue(jsonResponse(200, intentJson()));
    await pumpEmbeddedSheet(tester, harness, billingDetails: billingDetails);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
    await tester.pump();
  }

  group('per-field validation', () {
    testWidgets('one keystroke lights up no field, not even its own', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await tester.enterText(field('number'), '4');
      await tester.pump();
      expect(visibleErrors(), 0);
    });

    testWidgets('a definitively invalid value flags only its own field', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await tester.enterText(field('number'), testPan);
      await tester.enterText(field('expiry'), '13/30');
      await tester.pump();
      expect(find.text(l10n.errorInvalidExpiry), findsOneWidget);
      expect(visibleErrors(), 1);
    });

    testWidgets('a half-typed email is not flagged until the field is left', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await tester.enterText(field('email'), 'ada@');
      await tester.pump();
      expect(find.text(l10n.errorInvalidEmail), findsNothing);

      await tester.showKeyboard(field('street'));
      await tester.pump();
      expect(find.text(l10n.errorInvalidEmail), findsOneWidget);
    });

    testWidgets('incomplete fields become errors on submit, and an error '
        'clears as soon as the field is fixed', (tester) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await tester.enterText(field('cvc'), '1');
      await tester.pump();
      expect(visibleErrors(), 0);

      await tapPay(tester);
      await tester.pump();
      expect(harness.confirms, isEmpty);
      expect(find.text(l10n.errorInvalidSecurityCode), findsOneWidget);
      expect(find.text(l10n.errorInvalidCardNumber), findsOneWidget);

      await tester.enterText(field('number'), testPan);
      await tester.pump();
      expect(find.text(l10n.errorInvalidCardNumber), findsNothing);
      expect(find.text(l10n.errorInvalidSecurityCode), findsOneWidget);
    });
  });

  group('screen-reader announcements', () {
    testWidgets('typing announces nothing; a failed submit announces once', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      tester.takeAnnouncements();

      // Digit by digit (a 16-digit Luhn failure may still become a valid
      // 19-digit PAN, so it is not flagged yet).
      const pan = '4242424242424241';
      for (var i = 1; i <= pan.length; i++) {
        await tester.enterText(field('number'), pan.substring(0, i));
        await tester.pump();
      }
      // A visible per-field error is not announced while typing either.
      await tester.enterText(field('expiry'), '13/30');
      await tester.pump();
      expect(find.text(l10n.errorInvalidExpiry), findsOneWidget);
      await tester.enterText(field('name'), 'Ada');
      await tester.pump();
      expect(tester.takeAnnouncements(), isEmpty);

      await tapPay(tester);
      await tester.pump();
      final announced = tester.takeAnnouncements();
      expect(announced, hasLength(1));
      expect(announced.single.message, l10n.errorInvalidCardNumber);
    });
  });

  group('billing state', () {
    const sgBilling = UqpayBillingDetails(
      firstName: 'Ada',
      lastName: 'Lovelace',
      email: 'ada@example.com',
      address: UqpayAddress(
        countryCode: 'SG',
        city: 'Singapore',
        street: '1 Raffles Place',
        postcode: '048616',
      ),
    );

    testWidgets('optional for SG: an empty state pays, and is not sent', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness, billingDetails: sgBilling);
      await tester.enterText(field('number'), testPan);
      await tester.enterText(field('expiry'), '12/30');
      await tester.enterText(field('cvc'), testCvc);
      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tapPay(tester);
      await tester.pumpAndSettle();

      expect(find.text(l10n.errorStateRequired), findsNothing);
      expect(harness.confirms, hasLength(1));
      final body = harness.confirms.single.body!;
      expect(body, contains('"country_code":"SG"'));
      expect(body, isNot(contains('"state"')));
    });

    testWidgets('required for US: an empty state blocks the confirm', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(
        tester,
        harness,
        billingDetails: const UqpayBillingDetails(
          address: UqpayAddress(countryCode: 'US'),
        ),
      );
      await fillValidCard(tester, state: '');
      await tapPay(tester);
      await tester.pump();
      expect(harness.confirms, isEmpty);
      expect(find.text(l10n.errorStateRequired), findsOneWidget);
    });

    test('the required set is exactly the countries that need a state', () {
      expect(statesRequiredFor, <String>{
        'US',
        'CA',
        'AU',
        'IN',
        'BR',
        'MX',
      });
    });
  });

  testWidgets('numeric, email and postcode fields stay LTR in RTL', (
    tester,
  ) async {
    final harness = SheetHarness();
    harness.http.enqueue(jsonResponse(200, intentJson()));
    await pumpEmbeddedSheet(
      tester,
      harness,
      textDirection: TextDirection.rtl,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
    await tester.pump();
    for (final name in ['number', 'expiry', 'cvc', 'email', 'postcode']) {
      final text = tester.widget<TextField>(
        find.descendant(of: field(name), matching: find.byType(TextField)),
      );
      expect(text.textDirection, TextDirection.ltr, reason: name);
    }
    // Free text in the customer's own script keeps the ambient direction.
    final name = tester.widget<TextField>(
      find.descendant(of: field('name'), matching: find.byType(TextField)),
    );
    expect(name.textDirection, isNull);
  });

  testWidgets('name and email move to the next field, not "Done"', (
    tester,
  ) async {
    final harness = SheetHarness();
    await openCardForm(tester, harness);
    for (final name in ['name', 'email']) {
      final text = tester.widget<TextField>(
        find.descendant(of: field(name), matching: find.byType(TextField)),
      );
      expect(text.textInputAction, TextInputAction.next, reason: name);
    }
  });

  testWidgets('a cardholder name over 128 characters is refused by the form', (
    tester,
  ) async {
    final harness = SheetHarness();
    await openCardForm(tester, harness);
    await fillValidCard(
      tester,
      name: 'A' * (UqpayCardDetails.maxCardNameLength + 1),
    );
    await tapPay(tester);
    await tester.pump();
    expect(harness.confirms, isEmpty);
    expect(find.text(l10n.errorNameTooLong), findsOneWidget);

    await tester.enterText(
      field('name'),
      'A' * UqpayCardDetails.maxCardNameLength,
    );
    await tester.pump();
    expect(find.text(l10n.errorNameTooLong), findsNothing);
  });

  group('expiry formatter', () {
    String format(String input) => UqpayExpiryDateFormatter()
        .formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(text: input),
        )
        .text;

    test('pasted and autofilled forms read as month and year', () {
      expect(format('12/2030'), '12/30');
      expect(format('1/30'), '01/30');
      expect(format('01/2030'), '01/30');
      expect(format('12 / 30'), '12/30');
      expect(format('12-2030'), '12/30');
    });

    test('plain typing is unchanged', () {
      expect(format('1230'), '12/30');
      expect(format('4'), '04');
      expect(format('1'), '1');
      expect(format('12/3'), '12/3');
    });
  });

  group('Unicode digits', () {
    test('Arabic-Indic, Persian and full-width digits are converted', () {
      expect(digitsOf('٤٢٤٢ ٤٢٤٢'), '42424242');
      expect(digitsOf('۱۲۳۴'), '1234');
      expect(digitsOf('４２４２'), '4242');
      expect(digitsOf('12a-3 4'), '1234');
    });

    testWidgets('a full-width PAN is accepted by the field', (tester) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await tester.enterText(field('number'), '４２４２４２４２４２４２４２４２');
      await tester.pump();
      expect(find.text('4242 4242 4242 4242'), findsOneWidget);
    });
  });
}
