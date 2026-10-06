import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/l10n/l10n_fallbacks.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/uqpay_qr_view.dart';
import 'package:uqpay_sdk_flutter/src/sheet/sheet_model.dart';
import 'package:uqpay_sdk_flutter/src/sheet/widgets/qr_screen_view.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../sheet/support/sheet_harness.dart';
import '../support/fakes.dart';

/// QR-screen edge-case regressions: countdown restarts, `expires_at`
/// parsing, live-region use, URL-shaped QR payloads and the instruction text.
void main() {
  const l10n = UqpayLocalizations();
  final now = DateTime.utc(2026, 8, 18, 12);

  Map<String, Object?> qrAction(String payload, String expiresAt) =>
      <String, Object?>{
        'type': 'display_qr_code',
        'display_qr_code': <String, Object?>{
          'qr_code': payload,
          'expires_at': expiresAt,
        },
      };

  Future<void> pumpQr(
    WidgetTester tester,
    UqpayDisplayQrCode qr, {
    String methodType = 'paynow',
    Duration? remaining = const Duration(minutes: 5),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SheetQrScreenView(
              l10n: l10n,
              qr: qr,
              methodType: methodType,
              remaining: remaining,
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a re-served QR restarts the countdown on its own expiry '
      'instead of expiring with the old code', (tester) async {
    final harness = SheetHarness();
    final offering = intentJson()
      ..['available_payment_method_types'] = <Object?>['paynow'];
    harness.http
      ..enqueue(jsonResponse(200, offering))
      ..enqueue(jsonResponse(200, offering))
      ..enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: qrAction('00020101A', '2026-08-18T12:01:00Z'),
          ),
        ),
      );
    // Every poll from here on sees a re-issued code, valid until 12:30.
    for (var i = 0; i < 200; i++) {
      harness.http.enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: qrAction('00020101B', '2026-08-18T12:30:00Z'),
          ),
        ),
      );
    }
    await pumpEmbeddedSheet(
      tester,
      harness,
      presentation: const UqpaySheetPresentation.singleWallet('paynow'),
    );
    await pumpUntilIdle(tester, frames: 20);
    expect(find.text(l10n.qrExpiresIn('1:00')), findsOneWidget);

    for (var i = 0; i < 90; i++) {
      harness.clock.advance(const Duration(seconds: 1));
      await pumpUntilIdle(tester, frames: 2);
    }

    expect(find.text(l10n.qrExpiredTitle), findsNothing);
    expect(harness.results, isEmpty);
    expect(find.text(l10n.qrExpiresIn('28:30')), findsOneWidget);
  });

  group('expires_at parsing', () {
    test('a timestamp without an offset is UTC, not device-local', () {
      expect(
        UqpaySheetModel.parseQrExpiry('2026-08-18T12:10:00', now: now),
        DateTime.utc(2026, 8, 18, 12, 10),
      );
    });

    test('Z and explicit offsets keep their meaning', () {
      expect(
        UqpaySheetModel.parseQrExpiry('2026-08-18T12:10:00Z', now: now),
        DateTime.utc(2026, 8, 18, 12, 10),
      );
      expect(
        UqpaySheetModel.parseQrExpiry('2026-08-18T20:10:00+08:00', now: now),
        DateTime.utc(2026, 8, 18, 12, 10),
      );
    });

    test('absent, garbage, epoch-like and absurd horizons give no '
        'countdown', () {
      expect(UqpaySheetModel.parseQrExpiry(null, now: now), isNull);
      expect(UqpaySheetModel.parseQrExpiry('soon', now: now), isNull);
      expect(UqpaySheetModel.parseQrExpiry('1787054400', now: now), isNull);
      expect(
        UqpaySheetModel.parseQrExpiry('2036-08-18T12:00:00Z', now: now),
        isNull,
      );
    });

    test('the countdown shows hours once an hour or more remains', () {
      expect(
        formatQrRemaining(const Duration(minutes: 59, seconds: 59)),
        '59:59',
      );
      expect(
        formatQrRemaining(
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
      expect(
        formatQrRemaining(const Duration(hours: 23)),
        '23:00:00',
      );
    });
  });

  testWidgets('the per-second countdown is not a live region', (
    tester,
  ) async {
    await pumpQr(tester, const UqpayDisplayQrCode(qrCode: '00020101'));
    final countdown = find.byKey(const ValueKey<String>('uqpay-qr-countdown'));
    expect(countdown, findsOneWidget);
    expect(
      find.ancestor(
        of: countdown,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.liveRegion ?? false),
        ),
      ),
      findsNothing,
    );
  });

  group('URL-shaped qr_code without qr_code_url', () {
    testWidgets('a wallet deep link is encoded into the QR', (tester) async {
      await pumpQr(
        tester,
        const UqpayDisplayQrCode(qrCode: 'weixin://wxp/bizpayurl?pr=abc123'),
      );
      expect(find.byType(UqpayQrView), findsOneWidget);
      expect(find.text(l10n.qrImageLoadFailed), findsNothing);
    });

    testWidgets('a wallet https link is encoded into the QR', (tester) async {
      await pumpQr(
        tester,
        const UqpayDisplayQrCode(qrCode: 'https://qr.alipay.com/bax123'),
      );
      expect(find.byType(UqpayQrView), findsOneWidget);
    });

    testWidgets('an https QR picture is shown as an image', (tester) async {
      await pumpQr(
        tester,
        const UqpayDisplayQrCode(qrCode: 'https://qr.uqpay.com/abc.png'),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(UqpayQrView), findsNothing);
    });

    testWidgets('a hosted image still wins over a URL-shaped qr_code', (
      tester,
    ) async {
      await pumpQr(
        tester,
        const UqpayDisplayQrCode(
          qrCode: 'https://qr.alipay.com/bax123',
          qrCodeUrl: 'https://qr.uqpay.com/abc.png',
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(UqpayQrView), findsNothing);
    });
  });

  group('QR instruction', () {
    test('names a known wallet, and is method-agnostic otherwise', () {
      expect(l10n.qrInstructionFor('paynow'), l10n.qrInstruction('PayNow'));
      expect(l10n.qrInstructionFor(''), l10n.qrInstructionAnyApp);
      expect(l10n.qrInstructionFor('  '), l10n.qrInstructionAnyApp);
      expect(l10n.qrInstructionFor('mystery_wallet'), l10n.qrInstructionAnyApp);
    });

    testWidgets('a re-served QR with no method never shows a blank name', (
      tester,
    ) async {
      await pumpQr(
        tester,
        const UqpayDisplayQrCode(qrCode: '00020101'),
        methodType: '',
      );
      expect(find.text(l10n.qrInstructionAnyApp), findsOneWidget);
      expect(find.textContaining('with  to'), findsNothing);
    });
  });
}
