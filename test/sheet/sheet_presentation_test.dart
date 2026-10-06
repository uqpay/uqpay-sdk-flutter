import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/sheet/sheet_model.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';
import 'support/sheet_screens.dart';

/// Android-parity options on the sheet: `allowedPaymentMethods`, the three
/// `UqpaySheetPresentation`s and the sandbox test-mode banner.
void main() {
  const l10n = UqpayLocalizations();

  Map<String, Object?> offering(List<Object?> methods) =>
      intentJson()..['available_payment_method_types'] = methods;

  Finder tile(String type) =>
      find.byKey(ValueKey<String>('uqpay-method-$type'));

  group('allowedPaymentMethods', () {
    testWidgets('intersects with what the intent offers; unknown names are '
        'ignored', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(200, offering(<Object?>['card', 'paynow', 'grabpay'])),
      );
      await pumpEmbeddedSheet(
        tester,
        harness,
        allowedPaymentMethods: <String>{'grabpay', 'paynow', 'space_credits'},
      );
      await tester.pumpAndSettle();

      expect(tile('grabpay'), findsOneWidget);
      expect(tile('paynow'), findsOneWidget);
      expect(tile('card'), findsNothing);
      expect(find.byType(ListTile), findsNWidgets(2));
    });

    testWidgets('an empty intersection shows the no-methods screen rather '
        'than widening the list', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(200, offering(<Object?>['card', 'paynow'])),
      );
      await pumpEmbeddedSheet(
        tester,
        harness,
        allowedPaymentMethods: const <String>{'grabpay'},
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.noMethodsTitle), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(harness.confirms, isEmpty);
    });

    testWidgets('null means no restriction', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(200, offering(<Object?>['card', 'paynow', 'grabpay'])),
      );
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNWidgets(3));
    });
  });

  group('UqpaySheetPresentation.cardOnly', () {
    testWidgets('opens the card form directly with no way back to a list', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http.enqueue(
        jsonResponse(200, offering(<Object?>['card', 'paynow'])),
      );
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.cardOnly(),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.cardDetailsTitle), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('closing the card-only sheet before a confirm resolves '
        'Canceled, nothing sent', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.cardOnly(),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      await pumpUntilIdle(tester);

      expect(harness.results, hasLength(1));
      expect(harness.results.single, isA<UqpayPaymentCanceled>());
      expect(harness.confirms, isEmpty);
    });

    testWidgets('when the intent does not offer card, shows the no-methods '
        'screen', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['paynow'])));
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.cardOnly(),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.noMethodsTitle), findsOneWidget);
      expect(find.text(l10n.cardDetailsTitle), findsNothing);
    });

    testWidgets('on web it shows the documented card limitation, never the '
        'form', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(
        tester,
        harness,
        isWeb: true,
        presentation: const UqpaySheetPresentation.cardOnly(),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.webCardOnlyBody), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
    });
  });

  group('UqpaySheetPresentation.singleWallet', () {
    testWidgets('confirms the wallet immediately — exactly one confirm, no '
        'list — and shows its QR screen', (tester) async {
      final harness = SheetHarness();
      // Load read, the flow's own terminal-intent guard read, then the
      // confirm response carrying the QR action.
      harness.http
        ..enqueue(jsonResponse(200, offering(<Object?>['card', 'paynow'])))
        ..enqueue(jsonResponse(200, offering(<Object?>['card', 'paynow'])))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextActionExpiringIn(5),
            ),
          ),
        );
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.singleWallet('paynow'),
      );
      await pumpUntilIdle(tester, frames: 20);

      expect(find.byType(ListTile), findsNothing);
      expect(harness.confirms, hasLength(1));
      final body = Map<String, Object?>.from(
        jsonDecode(harness.confirms.single.body!) as Map,
      );
      final method = Map<String, Object?>.from(body['payment_method']! as Map);
      expect(method['type'], 'paynow');
      expect(find.text(l10n.qrInstruction('PayNow')), findsOneWidget);
    });

    testWidgets('a rebuild never confirms twice', (tester) async {
      final harness = SheetHarness();
      harness.http
        ..enqueue(jsonResponse(200, offering(<Object?>['paynow'])))
        ..enqueue(jsonResponse(200, offering(<Object?>['paynow'])))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextActionExpiringIn(5),
            ),
          ),
        );
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.singleWallet('paynow'),
      );
      await pumpUntilIdle(tester, frames: 20);
      await tester.pump(const Duration(seconds: 1));
      await pumpUntilIdle(tester, frames: 20);

      expect(harness.confirms, hasLength(1));
    });

    testWidgets('a wallet the intent does not offer shows the no-methods '
        'screen and sends nothing', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.singleWallet('grabpay'),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.noMethodsTitle), findsOneWidget);
      expect(harness.confirms, isEmpty);
    });

    test('singleWallet("card") is a programmer error', () {
      expect(
        () => UqpaySheetModel.validatePresentation(
          presentation: const UqpaySheetPresentation.singleWallet('card'),
          allowedPaymentMethods: null,
        ),
        throwsArgumentError,
      );
      expect(
        () => UqpaySheetModel.validatePresentation(
          presentation: const UqpaySheetPresentation.singleWallet('  '),
          allowedPaymentMethods: null,
        ),
        throwsArgumentError,
      );
    });

    test('a presentation outside allowedPaymentMethods is a programmer '
        'error, before any request', () {
      expect(
        () => UqpaySheetModel.validatePresentation(
          presentation: const UqpaySheetPresentation.singleWallet('paynow'),
          allowedPaymentMethods: const <String>{'card'},
        ),
        throwsArgumentError,
      );
      expect(
        () => UqpaySheetModel.validatePresentation(
          presentation: const UqpaySheetPresentation.cardOnly(),
          allowedPaymentMethods: const <String>{'paynow'},
        ),
        throwsArgumentError,
      );
      // methodList never conflicts, even with an empty allow-list.
      UqpaySheetModel.validatePresentation(
        presentation: const UqpaySheetPresentation.methodList(),
        allowedPaymentMethods: const <String>{},
      );
    });

    testWidgets('the embeddable widget surfaces the programmer error at '
        'build time', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(
        tester,
        harness,
        presentation: const UqpaySheetPresentation.singleWallet('card'),
      );
      expect(tester.takeException(), isA<ArgumentError>());
    });
  });

  group('sandbox test-mode banner', () {
    testWidgets('is drawn in sandbox, with a screen-reader label', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('uqpay-test-mode-banner')),
        findsOneWidget,
      );
      expect(find.text(l10n.testModeBanner), findsOneWidget);
      expect(
        find.bySemanticsLabel(l10n.testModeBannerSemantics),
        findsOneWidget,
      );
    });

    testWidgets('never appears in production', (tester) async {
      final harness = SheetHarness();
      final production = TrackingPayments(
        sdk: sdkWithTokens(
          const <String>['tok'],
          environment: UqpayEnvironment.production,
        ),
        httpClient: harness.http,
        clock: harness.clock,
        storage: harness.storage,
        pollingPolicy: PollingPolicy(jitter: 0),
        deviceIpResolver: () async => '198.51.100.7',
      );
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(tester, harness, payments: production);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('uqpay-test-mode-banner')),
        findsNothing,
      );
      expect(find.text(l10n.testModeBanner), findsNothing);
    });
  });

  group('embedded sheet delivers onResult exactly once', () {
    testWidgets('two close taps on the result screen call onResult once', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();

      final close = find.byKey(const ValueKey<String>('uqpay-close-button'));
      await tester.tap(close);
      await tester.tap(close);
      await pumpUntilIdle(tester);

      expect(harness.results, hasLength(1));
      expect(harness.results.single, isA<UqpayPaymentCompleted>());
    });

    testWidgets('removing the widget before any confirm delivers Canceled '
        'once, nothing sent', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await pumpUntilIdle(tester);

      expect(harness.results, hasLength(1));
      expect(harness.results.single, isA<UqpayPaymentCanceled>());
      expect(harness.confirms, isEmpty);
    });
  });
}
