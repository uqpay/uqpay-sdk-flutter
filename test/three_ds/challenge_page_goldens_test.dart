@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/fake_webview_platform.dart';

/// The golden matrix for the one full screen the SDK pushes outside the
/// sheet: the 3-D Secure [UqpayChallengePage], in light and dark, at text
/// scale 1.0 and 2.0, in LTR and RTL — 8 goldens under
/// `test/goldens/three_ds/`.
///
/// Same mechanism as `test/sheet/sheet_goldens_test.dart`: the real widget
/// on a 320 dp surface (the narrowest supported phone, so an overflow at
/// 2.0 fails here before any comparison). The webview body is
/// the real io implementation rendered through [FakeWebViewPlatform], whose
/// platform view paints nothing — the golden pins the SDK's own chrome
/// (app bar, localized title, close affordance, theming, direction), not
/// the issuer's ACS page, which the SDK never controls.
///
/// Regenerate deliberately, never casually:
///
/// ```sh
/// flutter test --update-goldens test/three_ds/challenge_page_goldens_test.dart
/// ```
void main() {
  const surface = Size(320, 640);
  const boundaryKey = ValueKey<String>('uqpay-challenge-boundary');

  const brightnesses = <String, Brightness>{
    'light': Brightness.light,
    'dark': Brightness.dark,
  };
  const scales = <String, double>{'x1_0': 1.0, 'x2_0': 2.0};
  const directions = <String, TextDirection>{
    'ltr': TextDirection.ltr,
    'rtl': TextDirection.rtl,
  };

  UqpayChallengeRequest request() => UqpayChallengeRequest(
    intentId: 'pi_123',
    action: const UqpayNextAction(
      rawType: 'redirect_to_url',
      redirectToUrl: UqpayRedirectToUrl(url: 'https://acs.example/challenge'),
    ),
    returnUrl: Uri.parse('https://shop.example/checkout/return'),
  );

  for (final brightness in brightnesses.entries) {
    for (final scale in scales.entries) {
      for (final direction in directions.entries) {
        final name =
            'challenge_page__${brightness.key}__${scale.key}__'
            '${direction.key}';
        testWidgets('golden: $name', (tester) async {
          tester.view.physicalSize = surface;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final platform = FakeWebViewPlatform.install();

          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                colorSchemeSeed: Colors.indigo,
                brightness: brightness.value,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale.value)),
                child: Directionality(
                  textDirection: direction.value,
                  child: RepaintBoundary(key: boundaryKey, child: child),
                ),
              ),
              home: UqpayChallengePage(
                request: request(),
                clock: ManualClock(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // The real webview body is mounted and loaded the challenge.
          expect(platform.last.loadedRequests, [
            Uri.parse('https://acs.example/challenge'),
          ]);
          expect(find.byKey(const ValueKey<String>('fake-webview')), findsOne);

          await expectLater(
            find.byKey(boundaryKey),
            matchesGoldenFile('../goldens/three_ds/$name.png'),
          );
        });
      }
    }
  }
}
