import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';

/// Screen/state behaviour of the drop-in sheet: every state is a screen,
/// the terminal-intent guard, the web card refusal, a rebuild never
/// confirming twice, and one amount path for every status.
void main() {
  const l10n = UqpayLocalizations();

  testWidgets('loading state shows a spinner, then the method list with '
      'card pinned first and unknown types hidden', (tester) async {
    final harness = SheetHarness();
    harness.http.enqueue(
      jsonResponse(
        200,
        intentJson()
          ..['available_payment_method_types'] = [
            'paynow',
            'card',
            'grabpay',
            'space_credits',
          ],
      ),
    );
    await pumpEmbeddedSheet(tester, harness);
    expect(find.text(l10n.loadingPayment), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text(l10n.chooseMethodTitle), findsOneWidget);
    final tiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.key! as ValueKey<String>).value)
        .toList();
    expect(tiles, [
      'uqpay-method-card',
      'uqpay-method-paynow',
      'uqpay-method-grabpay',
    ]);
    expect(harness.reads, hasLength(1));
  });

  testWidgets('terminal-intent guard: an already-SUCCEEDED intent shows the '
      'terminal state and never a working form', (tester) async {
    final harness = SheetHarness();
    harness.http
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text(l10n.successTitle), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text(l10n.chooseMethodTitle), findsNothing);

    await tester.tap(find.text(l10n.done));
    await tester.pumpAndSettle();
    expect(harness.results, hasLength(1));
    expect(harness.results.single, isA<UqpayPaymentCompleted>());
  });

  testWidgets('an already-CANCELLED intent shows the cancelled state', (
    tester,
  ) async {
    final harness = SheetHarness();
    harness.http
      ..enqueue(jsonResponse(200, intentJson(status: 'CANCELLED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'CANCELLED')));
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text(l10n.canceledTitle), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text(l10n.done));
    await tester.pump();
    expect(harness.results.single, isA<UqpayPaymentCanceled>());
  });

  testWidgets('an already-FAILED intent shows the failed state with the '
      'attempt code, never a form', (tester) async {
    final harness = SheetHarness();
    final body = intentJson(
      status: 'FAILED',
      attempt: failedAttempt('insufficient_funds'),
    );
    harness.http
      ..enqueue(jsonResponse(200, body))
      ..enqueue(jsonResponse(200, body));
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text(l10n.failedTitle), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(harness.http.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.tap(find.text(l10n.done));
    await tester.pump();
    final result = harness.results.single as UqpayPaymentFailed;
    expect(result.error.code, UqpayErrorCode.insufficientFunds);
  });

  testWidgets('an already-authorised (REQUIRES_CAPTURE) intent is Completed, '
      'no confirm', (tester) async {
    final harness = SheetHarness();
    harness.http
      ..enqueue(jsonResponse(200, intentJson(status: 'REQUIRES_CAPTURE')))
      ..enqueue(jsonResponse(200, intentJson(status: 'REQUIRES_CAPTURE')));
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text(l10n.successTitle), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(harness.http.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.tap(find.text(l10n.done));
    await tester.pump();
    expect(harness.results.single, isA<UqpayPaymentCompleted>());
  });

  testWidgets('the US spelling CANCELED is a cancelled intent too', (
    tester,
  ) async {
    final harness = SheetHarness();
    harness.http
      ..enqueue(jsonResponse(200, intentJson(status: 'CANCELED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'CANCELED')));
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text(l10n.canceledTitle), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text(l10n.done));
    await tester.pump();
    expect(harness.results.single, isA<UqpayPaymentCanceled>());
  });

  testWidgets('load failure shows the error state with retry, and retry '
      'reloads', (tester) async {
    final harness = SheetHarness();
    harness.http.enqueue(
      jsonResponse(500, {'code': '', 'type': '', 'message': ''}),
    );
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text(l10n.loadFailedTitle), findsOneWidget);
    expect(find.text(l10n.retry), findsOneWidget);

    harness.http.enqueue(jsonResponse(200, intentJson()));
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chooseMethodTitle), findsOneWidget);
    expect(harness.reads, hasLength(2));
  });

  testWidgets('an intent with only unrenderable methods shows the empty '
      'state', (tester) async {
    final harness = SheetHarness();
    harness.http.enqueue(
      jsonResponse(
        200,
        intentJson()
          ..['available_payment_method_types'] = [
            'space_credits',
            'paypal_unsupported',
          ],
      ),
    );
    await pumpEmbeddedSheet(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text(l10n.noMethodsTitle), findsOneWidget);
    expect(find.text(l10n.noMethodsBody), findsOneWidget);
  });

  group('web card refusal', () {
    testWidgets('on web the card method is hidden, the limitation is shown '
        'and wallets are offered', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson()
            ..['available_payment_method_types'] = [
              'card',
              'paynow',
              'grabpay',
            ],
        ),
      );
      await pumpEmbeddedSheet(tester, harness, isWeb: true);
      await tester.pumpAndSettle();

      expect(find.text(l10n.webCardUnavailableNotice), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('uqpay-method-card')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('uqpay-method-paynow')),
        findsOneWidget,
      );
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('on web a card-only intent shows the documented limitation '
        'and never the card form', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson()..['available_payment_method_types'] = ['card'],
        ),
      );
      await pumpEmbeddedSheet(tester, harness, isWeb: true);
      await tester.pumpAndSettle();

      expect(find.text(l10n.webCardOnlyBody), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('on mobile the same intent renders the card form', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson()..['available_payment_method_types'] = ['card'],
        ),
      );
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await tester.pump();
      // number, expiry, CVC, name, email, street, city, state, postcode —
      // every one of which the gateway requires on a card confirm — plus the
      // country picker, which is a dropdown rather than a text field.
      expect(find.byType(TextFormField), findsNWidgets(9));
      expect(
        find.byKey(const ValueKey<String>('uqpay-card-country')),
        findsOneWidget,
      );
    });
  });

  group('card flow', () {
    Future<void> openCardForm(WidgetTester tester, SheetHarness harness) async {
      harness.http.enqueue(jsonResponse(200, intentJson()));
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await tester.pump();
    }

    testWidgets('a valid card confirm reaches success and delivers the '
        'result on close', (tester) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester);

      harness.http
        ..enqueue(jsonResponse(200, intentJson())) // confirm guard GET
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tapPay(tester);
      await tester.pumpAndSettle();

      expect(harness.confirms, hasLength(1));
      expect(find.text(l10n.successTitle), findsOneWidget);

      await tester.tap(find.text(l10n.done));
      await tester.pump();
      expect(harness.results.single, isA<UqpayPaymentCompleted>());
    });

    testWidgets('invalid fields block the confirm and show messages', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester, number: '4242424242424241', expiry: '13/30');

      await tapPay(tester);
      await tester.pump();

      expect(harness.confirms, isEmpty);
      expect(find.text(l10n.errorInvalidCardNumber), findsOneWidget);
      expect(find.text(l10n.errorInvalidExpiry), findsOneWidget);
    });

    testWidgets('a past expiry date is rejected', (tester) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      // ManualClock's "now" is 2026-08-18.
      await fillValidCard(tester, expiry: '07/26');
      await tapPay(tester);
      await tester.pump();
      expect(harness.confirms, isEmpty);
      expect(find.text(l10n.errorCardExpired), findsOneWidget);
    });

    testWidgets('a 19-digit UnionPay PAN is accepted end-to-end', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester, number: '6212345678901234569');

      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tapPay(tester);
      await tester.pumpAndSettle();

      expect(harness.confirms, hasLength(1));
      final body = harness.confirms.single.body!;
      expect(body, contains('6212345678901234569'));
      expect(body, contains('"network":"unionpay"'));
    });

    testWidgets('the confirm carries billing.email — without it the gateway '
        'rejects the whole payment', (tester) async {
      // Regression: the sheet built `billing` from the cardholder name only
      // and `toJson` strips nulls, so `billing.email` was absent and every
      // card confirm came back 400 `invalid_payment_method: invalid
      // billing.email`. Found against the live sandbox; no mocked
      // test could have caught it, so this one pins the payload shape.
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester, email: 'grace@example.com');

      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tapPay(tester);
      await tester.pumpAndSettle();

      final body = harness.confirms.single.body!;
      expect(body, contains('"email":"grace@example.com"'));
    });

    testWidgets('merchant billing details prefill the form and carry the '
        'fields it does not ask for', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, intentJson()));
      await pumpEmbeddedSheet(
        tester,
        harness,
        billingDetails: const UqpayBillingDetails(
          firstName: 'Ada',
          lastName: 'Lovelace',
          email: 'ada@example.com',
          phoneNumber: '+6591234567',
          address: UqpayAddress(
            countryCode: 'SG',
            state: 'Central',
            city: 'Singapore',
            street: '1 Raffles Place',
            postcode: '048616',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await tester.pump();

      // Prefilled, and still editable — these are ordinary fields.
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);
      expect(find.text('1 Raffles Place'), findsOneWidget);
      expect(find.text('Singapore'), findsWidgets);
      expect(find.text('048616'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('uqpay-card-number')),
        testPan,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('uqpay-card-expiry')),
        '12/30',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('uqpay-card-cvc')),
        testCvc,
      );
      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tapPay(tester);
      await tester.pumpAndSettle();

      final body = harness.confirms.single.body!;
      expect(body, contains('"email":"ada@example.com"'));
      expect(body, contains('"country_code":"SG"'));
      expect(body, contains('"street":"1 Raffles Place"'));
      expect(body, contains('"postcode":"048616"'));
      // The form asks for neither phone nor state; both ride along from the
      // merchant's details.
      expect(body, contains('"phone_number":"+6591234567"'));
      expect(body, contains('"state":"Central"'));
    });

    testWidgets('an invalid email blocks the confirm before it leaves', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester, email: 'not-an-address');

      await tapPay(tester);
      await tester.pumpAndSettle();

      expect(harness.confirms, isEmpty);
      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('double-tap in one frame produces exactly one confirm', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester);

      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final button = find.byKey(const ValueKey<String>('uqpay-pay-button'));
      // The full billing form pushes the button below the fold on a test
      // viewport; scroll it in before measuring, or both taps land on air.
      await tester.ensureVisible(button);
      await tester.pump();
      // Two taps before any frame is pumped.
      final center = tester.getCenter(button);
      await tester.tapAt(center);
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(harness.confirms, hasLength(1));
    });

    testWidgets('taps in consecutive frames still produce one confirm', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester);

      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final button = find.byKey(const ValueKey<String>('uqpay-pay-button'));
      await tester.ensureVisible(button);
      await tester.pump();
      final center = tester.getCenter(button);
      await tester.tapAt(center);
      await tester.pump();
      // The form has been replaced by the processing screen; a second tap
      // lands on nothing tappable.
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(harness.confirms, hasLength(1));
    });

    testWidgets('a declined card offers try-again, which reloads the intent', (
      tester,
    ) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await fillValidCard(tester);

      harness.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(attempt: failedAttempt('card_declined')),
          ),
        );
      await tapPay(tester);
      await tester.pumpAndSettle();

      expect(find.text(l10n.failedTitle), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);

      harness.http.enqueue(jsonResponse(200, intentJson()));
      await tester.tap(find.text(l10n.retry));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chooseMethodTitle), findsOneWidget);
    });

    testWidgets('the back affordance returns from the form to the method '
        'list', (tester) async {
      final harness = SheetHarness();
      await openCardForm(tester, harness);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(find.text(l10n.chooseMethodTitle), findsOneWidget);
    });
  });

  group('one amount path for every status', () {
    String expectedAmount() => UqpayAmount.parse(
      '8.98',
    ).format(currencyCode: 'SGD', locale: 'en_US');

    String renderedAmount(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey<String>('uqpay-amount')))
        .data!;

    for (final status in [
      'REQUIRES_PAYMENT_METHOD',
      'PENDING',
      'SUCCEEDED',
    ]) {
      testWidgets('status $status renders the identical amount string', (
        tester,
      ) async {
        final harness = SheetHarness();
        // The sheet reads the intent once. A terminal status then reconciles
        // (one more read); a non-terminal, non-payable one (PENDING) starts a
        // watching flow whose prepare read is that second response — after
        // which it waits on the ManualClock, so nothing polls further and no
        // spinner is left animating for `pumpAndSettle` to chase.
        harness.http
          ..enqueue(jsonResponse(200, intentJson(status: status)))
          ..enqueue(jsonResponse(200, intentJson(status: status)));
        await pumpEmbeddedSheet(tester, harness);
        await pumpUntilIdle(tester);

        expect(renderedAmount(tester), expectedAmount());
        // Regression: the PENDING path must never divide.
        expect(renderedAmount(tester), contains('8.98'));
      });
    }
  });

  testWidgets('merchant localizations override every visible string', (
    tester,
  ) async {
    final harness = SheetHarness();
    harness.http.enqueue(jsonResponse(200, intentJson()));
    await pumpEmbeddedSheet(
      tester,
      harness,
      localizations: const _GermanStrings(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Zahlungsart wählen'), findsOneWidget);
    expect(find.text('Zahlung'), findsOneWidget);
  });
}

class _GermanStrings extends UqpayLocalizations {
  const _GermanStrings();

  @override
  String get paySheetTitle => 'Zahlung';

  @override
  String get chooseMethodTitle => 'Zahlungsart wählen';
}
