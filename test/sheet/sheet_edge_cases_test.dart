import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/qr_screen_view.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';

/// The awkward corners: QR payloads the sheet cannot encode, server-hosted
/// QR images, the empty-method dead end, and the redirect whose return URL
/// the server forgot to echo.
void main() {
  const l10n = UqpayLocalizations();

  Future<void> pumpQr(WidgetTester tester, UqpayDisplayQrCode qr) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SheetQrScreenView(
              l10n: l10n,
              qr: qr,
              methodType: 'paynow',
              remaining: const Duration(minutes: 1, seconds: 5),
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('QR screen', () {
    testWidgets('a server-hosted QR image is shown with its accessibility '
        'label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpQr(
        tester,
        const UqpayDisplayQrCode(qrCodeUrl: 'https://qr.uqpay.com/abc.png'),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(Image)).label,
        contains(l10n.qrCodeSemanticLabel),
      );
      expect(find.text(l10n.qrExpiresIn('1:05')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a next action with neither payload nor image says so '
        'instead of showing a blank square', (tester) async {
      await pumpQr(tester, const UqpayDisplayQrCode());
      expect(find.text(l10n.qrImageLoadFailed), findsOneWidget);
    });

    testWidgets('a payload no QR version can hold degrades to the failure '
        'text and never throws', (tester) async {
      await pumpQr(tester, UqpayDisplayQrCode(qrCode: 'A' * 5000));
      expect(find.text(l10n.qrImageLoadFailed), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a lapsed countdown renders 0:00, never a negative time', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SheetQrScreenView(
              l10n: l10n,
              qr: const UqpayDisplayQrCode(qrCode: '00020101'),
              methodType: 'paynow',
              remaining: const Duration(seconds: -30),
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(l10n.qrExpiresIn('0:00')), findsOneWidget);
    });
  });

  testWidgets('the empty-method screen closes with a Canceled result — no '
      'dead end', (tester) async {
    final harness = SheetHarness();
    harness.http.enqueue(
      jsonResponse(
        200,
        intentJson()..['available_payment_method_types'] = <Object?>['nope'],
      ),
    );
    await pumpEmbeddedSheet(tester, harness);
    await pumpUntilIdle(tester);
    expect(find.text(l10n.noMethodsTitle), findsOneWidget);

    await tester.tap(find.text(l10n.close));
    await pumpUntilIdle(tester);

    expect(harness.results.single, isA<UqpayPaymentCanceled>());
    expect(
      (harness.results.single as UqpayPaymentCanceled).reason,
      UqpayCancelReason.userTappedCancel,
    );
  });

  testWidgets('a redirect whose return URL the server did not echo is '
      'presented with the registered merchant return URL', (tester) async {
    final harness = SheetHarness();
    final presenter = RecordingPresenter();
    harness.http
      ..enqueue(jsonResponse(200, intentJson()))
      ..enqueue(jsonResponse(200, intentJson()))
      ..enqueue(
        jsonResponse(
          200,
          // Neither the intent nor the action carries a return URL: the
          // flow has only its unmatchable sentinel to offer.
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: <String, Object?>{
              'type': 'redirect_to_url',
              // No `return_url`: the server omitted its echo.
              'redirect_to_url': <String, Object?>{
                'url': 'https://acs.example/challenge',
              },
            },
          )..remove('return_url'),
        ),
      )
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final future = UqpayPaymentSheet.present(
      context,
      payments: harness.payments,
      intentId: kIntentId,
      returnUrl: kReturnUrl,
      clock: harness.clock,
      isWebPlatform: false,
      challengePresenter: presenter,
    );
    unawaited(future.then(harness.results.add));
    await pumpUntilIdle(tester, frames: 40);
    await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-paynow')));
    await pumpUntilIdle(tester, frames: 40);

    expect(presenter.requests, hasLength(1));
    expect(
      presenter.requests.single.returnUrl,
      kReturnUrl,
      reason:
          'the sheet substitutes the registered return URL for the '
          "flow's unmatchable sentinel",
    );

    await tester.tap(find.text(l10n.done));
    await pumpUntilIdle(tester, frames: 40);
    expect(await future, isA<UqpayPaymentCompleted>());
  });
}
