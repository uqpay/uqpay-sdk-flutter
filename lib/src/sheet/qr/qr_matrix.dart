import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_error_correction.dart';

/// An immutable, fully-encoded QR symbol: a square grid of dark and light
/// modules produced by `UqpayQrEncoder.encode`.
///
/// Coordinates are `(x, y)` with `x` the column and `y` the row, both
/// zero-based from the top-left module. The matrix contains **no quiet
/// zone** — renderers must surround it with at least [quietZoneModules]
/// modules of light margin (ISO/IEC 18004:2015 §6.3.8).
@immutable
class UqpayQrMatrix {
  /// Builds a matrix from a row-major list of [modules] (`true` = dark).
  ///
  /// Internal: instances are produced by `UqpayQrEncoder`; nothing in the
  /// SDK builds one by hand. [modules] must contain exactly
  /// `moduleCount * moduleCount` entries for the given [version]; the list
  /// is copied, so later mutation of the argument cannot affect this
  /// matrix.
  UqpayQrMatrix({
    required this.version,
    required this.errorCorrection,
    required this.maskPattern,
    required List<bool> modules,
  }) : moduleCount = 17 + 4 * version,
       _modules = Uint8List.fromList([
         for (final isDark in modules)
           if (isDark) 1 else 0,
       ]) {
    if (version < 1 || version > 40) {
      throw ArgumentError.value(version, 'version', 'must be 1..40');
    }
    if (maskPattern < 0 || maskPattern > 7) {
      throw ArgumentError.value(maskPattern, 'maskPattern', 'must be 0..7');
    }
    if (modules.length != moduleCount * moduleCount) {
      throw ArgumentError.value(
        modules.length,
        'modules',
        'must have moduleCount^2 == ${moduleCount * moduleCount} entries',
      );
    }
  }

  /// The minimum quiet-zone width, in modules, that must surround the
  /// symbol on every side (ISO/IEC 18004:2015 §6.3.8).
  static const int quietZoneModules = 4;

  /// The symbol version, 1–40 (ISO/IEC 18004:2015 §6.3.1).
  final int version;

  /// The error-correction level the symbol was encoded at.
  final UqpayQrErrorCorrection errorCorrection;

  /// The data-mask pattern applied to the symbol, 0–7
  /// (ISO/IEC 18004:2015 §7.8.2).
  final int maskPattern;

  /// The number of modules along each side: `17 + 4 * version`.
  final int moduleCount;

  /// Row-major module colours, 1 = dark. Never exposed or mutated.
  final Uint8List _modules;

  /// Whether the module at column [x], row [y] is dark.
  ///
  /// Both coordinates must be in `0 <= v < moduleCount`.
  bool isDark(int x, int y) {
    if (x < 0 || y < 0 || x >= moduleCount || y >= moduleCount) {
      throw RangeError('($x, $y) outside $moduleCount x $moduleCount matrix');
    }
    return _modules[y * moduleCount + x] != 0;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! UqpayQrMatrix ||
        other.version != version ||
        other.errorCorrection != errorCorrection ||
        other.maskPattern != maskPattern) {
      return false;
    }
    for (var i = 0; i < _modules.length; i++) {
      if (other._modules[i] != _modules[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    version,
    errorCorrection,
    maskPattern,
    Object.hashAll(_modules),
  );

  @override
  String toString() =>
      'UqpayQrMatrix(version: $version, level: ${errorCorrection.name}, '
      'mask: $maskPattern, modules: ${moduleCount}x$moduleCount)';
}
