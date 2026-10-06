import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
// The stub is imported directly (bypassing the conditional import, which on
// the test VM would pick the io/webview branch) to test the web-build
// behaviour of UqpayChallengePage's body.
import 'package:uqpay_sdk_flutter/src/three_ds/webview_challenge_presenter_stub.dart'
    as stub;

import '../support/fakes.dart';

/// What a webview challenge does on platforms without a webview (web/wasm):
/// declares itself unsupported and completes `failed` fast, so a flow can
/// fall back and the customer is never stuck.
///
/// The real (io) webview body is widget-tested through a fake
/// `WebViewPlatform` (`support/fake_webview_platform.dart`) in
/// `test/regression/edge_3ds_webview_page_test.dart`; its navigation policy
/// is also tested as a pure function in `return_url_matcher_test.dart`.
void main() {
  UqpayChallengeRequest request() => UqpayChallengeRequest(
    intentId: 'pi_123',
    action: const UqpayNextAction(
      rawType: 'redirect_to_url',
      redirectToUrl: UqpayRedirectToUrl(
        url: 'https://acs.example/challenge',
        returnUrl: 'https://shop.example/return',
      ),
    ),
    returnUrl: Uri.parse('https://shop.example/return'),
  );

  test('the stub declares webview challenges unsupported', () {
    expect(stub.isWebviewChallengeSupported, isFalse);
  });

  test('the unsupported error is typed, not unknown', () {
    final error = stub.unsupportedWebviewError();
    expect(error.code, UqpayErrorCode.invalidConfiguration);
    expect(error.isRetryable, isFalse);
    expect(error.userMessage, isNotEmpty);
  });

  testWidgets('the stub body completes failed after the first frame '
      '(a flow waiting on it is never stuck)', (tester) async {
    final outcomes = <UqpayChallengeOutcome>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: stub.buildChallengeView(
            request: request(),
            clock: FakeClock(),
            onOutcome: outcomes.add,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(outcomes, hasLength(1));
    expect(outcomes.single, isA<UqpayChallengeFailed>());
    expect(
      (outcomes.single as UqpayChallengeFailed).error.code,
      UqpayErrorCode.invalidConfiguration,
    );
    expect(find.textContaining('Verification'), findsOneWidget);
  });
}
