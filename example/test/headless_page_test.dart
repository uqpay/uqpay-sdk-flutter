import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uqpay_sdk_flutter_example/src/backend/merchant_backend.dart';
import 'package:uqpay_sdk_flutter_example/src/config/app_config.dart';
import 'package:uqpay_sdk_flutter_example/src/pages/headless_page.dart';
import 'package:uqpay_sdk_flutter_example/src/state/demo_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/state/theme_controller.dart';

const String _backendUrl = 'http://localhost:8787';

/// The billing fields the gateway requires on a card confirm, keyed by
/// widget key: the label the tester sees and the demo value prefilled so a
/// sandbox payment works without typing an address.
const Map<String, (String label, String value)> _billingFields =
    <String, (String, String)>{
      'billing-email-field': ('Email', 'shopper@example.com'),
      'billing-street-field': ('Address', '1 Main Street'),
      'billing-city-field': ('City', 'Springfield'),
      'billing-state-field': ('State or province', 'CA'),
      'billing-postcode-field': ('Postal code', '90210'),
      'billing-country-field': ('Country code', 'US'),
    };

/// A backend that answers `POST /payment-intents` with a minimal intent so
/// the page renders its card section; everything else 404s.
http.Client _backend() => MockClient((request) async {
  if (request.url.path == '/payment-intents' && request.method == 'POST') {
    return http.Response(
      jsonEncode(<String, Object?>{
        'payment_intent_id': 'pi_headless_test',
        'intent_status': 'REQUIRES_PAYMENT_METHOD',
        'amount': '8.98',
        'currency': 'USD',
        'available_payment_method_types': <String>['card'],
      }),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
  return http.Response('{"code":"not_found"}', 404);
});

Future<DemoController> _controllerWithIntent() async {
  final controller = DemoController(
    config: AppConfig.resolve(
      environment: 'sandbox',
      backendUrl: _backendUrl,
      onBehalfOf: '',
    ),
    backend: MerchantBackend(baseUrl: _backendUrl, httpClient: _backend()),
    isWeb: false,
    currentUri: Uri.parse('http://localhost/'),
  );
  // Initialises the SDK handle the confirm path needs; the fake backend's
  // 404 on /health only marks the backend unreachable, which is irrelevant
  // here.
  await controller.bootstrap();
  final intent = await controller.createIntent();
  expect(intent, isNotNull, reason: controller.backendError?.toString());
  return controller;
}

Future<void> _pump(WidgetTester tester, DemoController controller) async {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: HeadlessPage(controller: controller, theme: ThemeController()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('card section has the card fields plus a billing block', (
    tester,
  ) async {
    final controller = await _controllerWithIntent();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    // The card fields that were always there.
    for (final key in <String>[
      'card-name-field',
      'card-number-field',
      'expiry-month-field',
      'expiry-year-field',
      'cvc-field',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }

    // The billing block: labelled exactly, prefilled with the demo values.
    for (final MapEntry(:key, value: (label, value))
        in _billingFields.entries) {
      final field = tester.widget<TextField>(find.byKey(Key(key)));
      expect(field.decoration?.labelText, label, reason: key);
      expect(field.controller?.text, value, reason: key);
    }
    expect(find.text('Billing'), findsOneWidget);
    expect(find.textContaining('gateway requires'), findsOneWidget);
  });

  testWidgets('a blank required billing field blocks the confirm', (
    tester,
  ) async {
    final controller = await _controllerWithIntent();
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.enterText(find.byKey(const Key('card-name-field')), 'A B');
    await tester.enterText(
      find.byKey(const Key('card-number-field')),
      '6250947000000014',
    );
    await tester.enterText(find.byKey(const Key('expiry-month-field')), '12');
    await tester.enterText(find.byKey(const Key('expiry-year-field')), '2033');
    await tester.enterText(find.byKey(const Key('cvc-field')), '123');
    await tester.enterText(find.byKey(const Key('billing-postcode-field')), '');

    await tester.tap(find.byKey(const Key('confirm-button')));
    await tester.pump();

    // The page refused before anything left the device: no flow started,
    // and the problem names the billing address.
    expect(find.byKey(const Key('headless-problem')), findsOneWidget);
    expect(find.textContaining('billing street'), findsOneWidget);
    expect(find.byKey(const Key('cancel-flow-button')), findsNothing);
  });
}
