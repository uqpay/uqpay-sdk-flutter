import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uqpay_sdk_flutter_example/src/backend/merchant_backend.dart';
import 'package:uqpay_sdk_flutter_example/src/config/app_config.dart';
import 'package:uqpay_sdk_flutter_example/src/demo_app.dart';
import 'package:uqpay_sdk_flutter_example/src/state/demo_controller.dart';

const String _backendUrl = 'http://localhost:8787';

AppConfig _config() => AppConfig.resolve(
  environment: 'sandbox',
  backendUrl: _backendUrl,
  onBehalfOf: '',
);

http.Client _healthyBackend() => MockClient((request) async {
  switch (request.url.path) {
    case '/health':
      return http.Response(
        jsonEncode(<String, Object?>{'ok': true, 'environment': 'sandbox'}),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    case '/client-token':
      return http.Response(
        jsonEncode(<String, Object?>{
          'auth_token': 'tok_for_tests',
          'expired_at':
              DateTime.now()
                  .add(const Duration(minutes: 30))
                  .millisecondsSinceEpoch ~/
              1000,
          'client_id': 'cli_demo',
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    default:
      return http.Response('{"code":"not_found"}', 404);
  }
});

http.Client _deadBackend() => MockClient((request) async {
  throw http.ClientException('Connection refused', request.url);
});

DemoController _controller(http.Client client) => DemoController(
  config: _config(),
  backend: MerchantBackend(baseUrl: _backendUrl, httpClient: client),
  isWeb: false,
  currentUri: Uri.parse('http://localhost/'),
);

Future<void> _pumpApp(WidgetTester tester, DemoController controller) async {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(DemoApp(controller: controller));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('shows the resolved configuration on screen', (tester) async {
    final controller = _controller(_healthyBackend());
    addTearDown(controller.dispose);

    await _pumpApp(tester, controller);

    expect(find.text('UQPAY SDK sample'), findsOneWidget);
    // The environment resolved from the build, and the origin it implies.
    expect(find.text('sandbox'), findsWidgets);
    expect(
      find.text('https://api-sandbox.uqpaytech.com'),
      findsOneWidget,
    );
    expect(find.text(_backendUrl), findsOneWidget);
    // The backend disclosed a client_id, so the SDK is configured with it.
    expect(find.text('cli_demo'), findsOneWidget);
    expect(controller.sdk?.clientId, 'cli_demo');
    // Sandbox is the active environment; no production banner.
    expect(find.byKey(const Key('production-banner')), findsNothing);
    expect(find.byKey(const Key('backend-error-summary')), findsNothing);
  });

  testWidgets('an unreachable backend says exactly what to do', (
    tester,
  ) async {
    final controller = _controller(_deadBackend());
    addTearDown(controller.dispose);

    await _pumpApp(tester, controller);

    expect(controller.backendStatus, BackendStatus.failed);
    expect(
      find.byKey(const Key('backend-error-summary')),
      findsOneWidget,
    );
    final detail = tester
        .widget<SelectableText>(find.byKey(const Key('backend-error-detail')))
        .data!;
    expect(detail, contains('Nothing answered at $_backendUrl'));
    expect(detail, contains('cd example/backend && tool/run.sh'));
    expect(detail, contains('10.0.2.2'));
    // The screen still works: the retry button is there.
    expect(find.byKey(const Key('retry-backend-button')), findsOneWidget);
  });

  testWidgets('production needs a deliberate confirmation', (tester) async {
    final controller = _controller(_healthyBackend());
    addTearDown(controller.dispose);

    await _pumpApp(tester, controller);
    await tester.tap(find.text('PRODUCTION'));
    await tester.pumpAndSettle();

    expect(find.text('Switch to PRODUCTION?'), findsOneWidget);
    await tester.tap(find.text('Stay on sandbox'));
    await tester.pumpAndSettle();

    expect(controller.environment.name, 'sandbox');
    expect(find.byKey(const Key('production-banner')), findsNothing);
  });

  testWidgets('the amount travels in major units, unscaled', (tester) async {
    final controller = _controller(_healthyBackend());
    addTearDown(controller.dispose);

    await _pumpApp(tester, controller);

    expect(find.text('"8.98" USD'), findsOneWidget);

    controller.setCurrency('JPY');
    await tester.pump();
    expect(controller.amount, '898');
    expect(find.text('"898" JPY'), findsOneWidget);
    expect(find.textContaining('898 yen, not 8.98'), findsOneWidget);

    controller.setCurrency('BHD');
    await tester.pump();
    expect(controller.amount, '8.980');
    expect(find.text('"8.980" BHD'), findsOneWidget);
  });
}
