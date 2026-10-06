import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_encoder.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_matrix.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/uqpay_qr_view.dart';

void main() {
  final matrix = UqpayQrEncoder.encode(
    // Split only at spaces inside the payload so concatenation stays
    // byte-identical to the wire string.
    '00020101021226730012SG.COM.UQPAY0127936009170000000000000000001'
    '0222UQPAY-MERCH-0000123456520458145303702540523.505802SG5919UQPAY '
    'TEST '
    'MERCHANT6009Singapore62390125UQPAY-REF-20260818-0000420506A1B2C3'
    '6304991F',
  );

  Widget host({required Widget child, double textScale = 1.0}) => MediaQuery(
    data: MediaQueryData(
      devicePixelRatio: 3,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF222222),
        child: Center(child: child),
      ),
    ),
  );

  group('golden', () {
    testWidgets('240 logical pixels', (tester) async {
      tester.view.physicalSize = const Size(720, 720);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(
          child: SizedBox.square(
            dimension: 240,
            child: UqpayQrView(matrix: matrix),
          ),
        ),
      );
      await expectLater(
        find.byType(UqpayQrView),
        matchesGoldenFile('../../goldens/qr/uqpay_qr_view_240.png'),
      );
    });

    testWidgets('96 logical pixels stays legible and square', (tester) async {
      tester.view.physicalSize = const Size(360, 360);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(
          child: SizedBox.square(
            dimension: 96,
            child: UqpayQrView(matrix: matrix),
          ),
        ),
      );
      await expectLater(
        find.byType(UqpayQrView),
        matchesGoldenFile('../../goldens/qr/uqpay_qr_view_96.png'),
      );
    });

    testWidgets('dark theme renders the identical black-on-white symbol', (
      tester,
    ) async {
      // The QR is deliberately theme-independent (see UqpayQrView docs):
      // a themed low-contrast QR stops scanning. Same golden as light.
      tester.view.physicalSize = const Size(720, 720);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Theme(
          data: ThemeData.dark(),
          child: host(
            child: SizedBox.square(
              dimension: 240,
              child: UqpayQrView(matrix: matrix),
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(UqpayQrView),
        matchesGoldenFile('../../goldens/qr/uqpay_qr_view_240.png'),
      );
    });
  });

  group('layout', () {
    testWidgets('no overflow at 320 dp width and textScaler 2.0', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(textScale: 2, child: UqpayQrView(matrix: matrix)),
      );
      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(CustomPaint).first);
      expect(size.width, lessThanOrEqualTo(320));
      expect(size.width, size.height, reason: 'must stay square');
    });

    testWidgets('tight non-square constraints paint without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(
          textScale: 2,
          child: Column(
            children: [Expanded(child: UqpayQrView(matrix: matrix))],
          ),
        ),
      );
      // The box is stretched to 320x480 by the tight flex constraints;
      // the painter centres the square symbol inside it. No exception
      // means no overflow and no painting outside bounds.
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CustomPaint).first).width, 320);
    });

    testWidgets('unbounded constraints fall back to a finite square', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: UqpayQrView(matrix: matrix),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(CustomPaint).first);
      expect(size.width, 240);
      expect(size.height, 240);
    });
  });

  group('accessibility', () {
    testWidgets('exposes a payment semantics label on an image node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          child: SizedBox.square(
            dimension: 200,
            child: UqpayQrView(matrix: matrix),
          ),
        ),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('Payment QR code'),
      );
      expect(node.flagsCollection.isImage, isTrue);
      handle.dispose();
    });

    testWidgets('the label is overridable for localisation', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          child: SizedBox.square(
            dimension: 200,
            child: UqpayQrView(
              matrix: matrix,
              semanticLabel: 'QR de pago',
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('QR de pago'), findsOneWidget);
      handle.dispose();
    });
  });

  group('painting contract', () {
    testWidgets('uses a RepaintBoundary', (tester) async {
      await tester.pumpWidget(
        host(
          child: SizedBox.square(
            dimension: 200,
            child: UqpayQrView(matrix: matrix),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(UqpayQrView),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
    });

    testWidgets('quiet zone default follows the matrix guidance', (
      tester,
    ) async {
      final view = UqpayQrView(matrix: matrix);
      expect(view.quietZoneModules, UqpayQrMatrix.quietZoneModules);
      expect(view.darkColor, const Color(0xFF000000));
      expect(view.lightColor, const Color(0xFFFFFFFF));
    });
  });
}
