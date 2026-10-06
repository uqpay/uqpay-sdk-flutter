import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_matrix.dart';

/// Renders a [UqpayQrMatrix] as a crisp, scannable QR image.
///
/// **The QR is deliberately not themed.** Scanners need maximum optical
/// contrast, so the defaults are pure black modules on a pure white field
/// and the sheet keeps them in dark mode too: restyling a QR to
/// match an app theme is how payment QRs silently stop scanning in the
/// field. [darkColor]/[lightColor] exist for tests and for merchants who
/// accept that risk knowingly — never wire them to `Theme.of(context)`.
///
/// Rendering details:
///
/// * module edges are snapped to whole device pixels so modules never
///   land on half-pixel boundaries and blur (antialiasing is off);
/// * the widget always paints square, centred in its constraints, and
///   sizes itself to the tightest finite constraint (falling back to
///   240 logical pixels when both axes are unbounded), so it cannot
///   overflow a 320 dp column at any text scale (it contains no
///   text);
/// * the light [quietZoneModules]-module margin required by
///   ISO/IEC 18004:2015 §6.3.8 is painted by the widget itself;
/// * the paint subtree is wrapped in a [RepaintBoundary] so sheet
///   animations never re-rasterise the matrix, and carries a
///   [Semantics] image label for screen readers.
class UqpayQrView extends StatelessWidget {
  /// Creates a QR view for [matrix].
  const UqpayQrView({
    required this.matrix,
    super.key,
    this.darkColor = const Color(0xFF000000),
    this.lightColor = const Color(0xFFFFFFFF),
    this.quietZoneModules = UqpayQrMatrix.quietZoneModules,
    this.semanticLabel = 'Payment QR code',
  }) : assert(quietZoneModules >= 0, 'quietZoneModules must be >= 0');

  /// The encoded symbol to draw.
  final UqpayQrMatrix matrix;

  /// Colour of dark modules. Defaults to pure black; see the class note
  /// before changing it.
  final Color darkColor;

  /// Colour of the light field and quiet zone. Defaults to pure white;
  /// see the class note before changing it.
  final Color lightColor;

  /// Width of the light margin painted around the symbol, in modules.
  /// Defaults to the ISO minimum of [UqpayQrMatrix.quietZoneModules].
  final int quietZoneModules;

  /// The accessibility label announced for the image.
  final String semanticLabel;

  /// Side length used when both incoming constraints are unbounded.
  static const double _fallbackSide = 240;

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return RepaintBoundary(
      child: Semantics(
        label: semanticLabel,
        image: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = _sideFor(constraints);
            return SizedBox(
              width: side,
              height: side,
              child: CustomPaint(
                isComplex: true,
                painter: _UqpayQrPainter(
                  matrix: matrix,
                  darkColor: darkColor,
                  lightColor: lightColor,
                  quietZoneModules: quietZoneModules,
                  devicePixelRatio: devicePixelRatio,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static double _sideFor(BoxConstraints constraints) {
    if (constraints.maxWidth.isFinite && constraints.maxHeight.isFinite) {
      return math.min(constraints.maxWidth, constraints.maxHeight);
    }
    if (constraints.maxWidth.isFinite) {
      return constraints.maxWidth;
    }
    if (constraints.maxHeight.isFinite) {
      return constraints.maxHeight;
    }
    return _fallbackSide;
  }
}

/// Paints the module grid with edges snapped to whole device pixels.
class _UqpayQrPainter extends CustomPainter {
  const _UqpayQrPainter({
    required this.matrix,
    required this.darkColor,
    required this.lightColor,
    required this.quietZoneModules,
    required this.devicePixelRatio,
  });

  final UqpayQrMatrix matrix;
  final Color darkColor;
  final Color lightColor;
  final int quietZoneModules;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    // Light field over everything, including slack outside the symbol.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = lightColor
        ..isAntiAlias = false,
    );

    final totalModules = matrix.moduleCount + 2 * quietZoneModules;
    final extent = size.shortestSide;
    if (extent <= 0 || totalModules <= 0) {
      return;
    }
    final scale = extent / totalModules;

    // Snap every grid line to a whole device pixel. Adjacent modules
    // share an edge, so snapping edges (not origins+sizes) leaves no
    // hairline gaps or overlaps.
    double snap(double value) =>
        (value * devicePixelRatio).roundToDouble() / devicePixelRatio;
    final left = (size.width - extent) / 2;
    final top = (size.height - extent) / 2;
    final xEdges = List<double>.generate(
      totalModules + 1,
      (i) => snap(left + i * scale),
      growable: false,
    );
    final yEdges = List<double>.generate(
      totalModules + 1,
      (i) => snap(top + i * scale),
      growable: false,
    );

    final darkPath = Path();
    for (var y = 0; y < matrix.moduleCount; y++) {
      for (var x = 0; x < matrix.moduleCount; x++) {
        if (matrix.isDark(x, y)) {
          final gx = x + quietZoneModules;
          final gy = y + quietZoneModules;
          darkPath.addRect(
            Rect.fromLTRB(
              xEdges[gx],
              yEdges[gy],
              xEdges[gx + 1],
              yEdges[gy + 1],
            ),
          );
        }
      }
    }
    canvas.drawPath(
      darkPath,
      Paint()
        ..color = darkColor
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_UqpayQrPainter oldDelegate) =>
      oldDelegate.matrix != matrix ||
      oldDelegate.darkColor != darkColor ||
      oldDelegate.lightColor != lightColor ||
      oldDelegate.quietZoneModules != quietZoneModules ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
