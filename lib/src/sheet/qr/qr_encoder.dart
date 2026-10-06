import 'dart:convert';
import 'dart:typed_data';

import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_error_correction.dart';
import 'package:uqpay_sdk_flutter/src/sheet/qr/qr_matrix.dart';

/// Thrown when a payload cannot fit in any QR version (1–40) at the
/// requested error-correction level.
///
/// This is a programmer/data error, not an expected outcome: EMVCo
/// merchant-presented payloads are bounded at 512 characters (EMVCo QCPS
/// §4.1), far below the version-40 byte capacity at level M (2331 bytes),
/// so hitting this in the payment flow means the server sent something
/// that is not a QR payload at all.
class UqpayQrCapacityError extends Error {
  /// Creates the error for a payload of [payloadBytes] bytes at [level].
  UqpayQrCapacityError({required this.payloadBytes, required this.level});

  /// The size of the rejected payload in bytes (after UTF-8 encoding).
  final int payloadBytes;

  /// The error-correction level the payload was measured against.
  final UqpayQrErrorCorrection level;

  @override
  String toString() =>
      'UqpayQrCapacityError: $payloadBytes bytes exceed QR version 40 '
      'capacity at level ${level.name}';
}

/// A pure-Dart QR encoder implementing ISO/IEC 18004:2015 for model-2
/// symbols, versions 1–40, byte mode.
///
/// The SDK uses it to render the raw EMVCo payload the API returns in
/// `next_action.display_qr_code.qr_code` without any
/// third-party dependency. Byte mode alone is deliberate: EMVCo payloads
/// are ASCII, and a single-segment byte encoding is the simplest pipeline
/// to verify exhaustively. Kanji mode, ECI,
/// structured append and Micro QR are intentionally not implemented.
abstract final class UqpayQrEncoder {
  /// Encodes [payload] as a QR symbol and returns its module matrix.
  ///
  /// The payload is encoded as a single byte-mode segment of its UTF-8
  /// bytes (for EMVCo payloads this is plain ASCII, byte for byte). The
  /// smallest version whose data capacity at [errorCorrection] fits the
  /// payload is selected automatically.
  ///
  /// [maskPattern] forces a specific data-mask pattern (0–7) and exists
  /// for conformance tests against published vectors; leave it `null` in
  /// production so the ISO §7.8.3 penalty evaluation picks the best mask.
  ///
  /// Throws [ArgumentError] if [payload] is empty or [maskPattern] is out
  /// of range, and [UqpayQrCapacityError] if the payload exceeds the
  /// version-40 capacity.
  static UqpayQrMatrix encode(
    String payload, {
    UqpayQrErrorCorrection errorCorrection = UqpayQrErrorCorrection.medium,
    int? maskPattern,
  }) {
    if (payload.isEmpty) {
      throw ArgumentError.value(payload, 'payload', 'must not be empty');
    }
    if (maskPattern != null && (maskPattern < 0 || maskPattern > 7)) {
      throw ArgumentError.value(maskPattern, 'maskPattern', 'must be 0..7');
    }
    final data = utf8.encode(payload);
    final version = _selectVersion(data.length, errorCorrection);
    final codewords = _buildCodewords(data, version, errorCorrection);
    return _QrModulePlacer(version, errorCorrection).place(
      codewords,
      forcedMask: maskPattern,
    );
  }

  /// Returns the byte-mode character capacity of [version] at [level],
  /// derived from the codeword tables (ISO/IEC 18004:2015 Table 7).
  static int byteCapacity(int version, UqpayQrErrorCorrection level) =>
      (_dataCodewords(version, level) * 8 -
          _modeIndicatorBits -
          _characterCountBits(version)) ~/
      8;

  static const int _modeIndicatorBits = 4;

  /// Byte-mode character-count indicator length (ISO §7.4.1 Table 3).
  static int _characterCountBits(int version) => version <= 9 ? 8 : 16;

  static int _selectVersion(int byteLength, UqpayQrErrorCorrection level) {
    for (var version = 1; version <= 40; version++) {
      if (byteLength <= byteCapacity(version, level)) {
        return version;
      }
    }
    throw UqpayQrCapacityError(payloadBytes: byteLength, level: level);
  }

  /// Total codewords in [version] (ISO Table 1, derived from the module
  /// count formula rather than transcribed).
  static int _totalCodewords(int version) {
    var bits = (16 * version + 128) * version + 64;
    if (version >= 2) {
      final numAlign = version ~/ 7 + 2;
      bits -= (25 * numAlign - 10) * numAlign - 55;
      if (version >= 7) {
        bits -= 36;
      }
    }
    return bits ~/ 8;
  }

  static int _dataCodewords(int version, UqpayQrErrorCorrection level) =>
      _totalCodewords(version) -
      _eccCodewordsPerBlock[level.index][version - 1] *
          _numEccBlocks[level.index][version - 1];

  /// Builds the final interleaved codeword sequence: segment bits,
  /// terminator, pad bits, pad codewords, per-block Reed–Solomon ECC and
  /// block interleaving (ISO §7.4.9–7.6).
  static Uint8List _buildCodewords(
    List<int> data,
    int version,
    UqpayQrErrorCorrection level,
  ) {
    final dataCapacityBits = _dataCodewords(version, level) * 8;
    final bits = _BitBuffer()
      ..append(4, _modeIndicatorBits) // Byte mode indicator 0b0100.
      ..append(data.length, _characterCountBits(version));
    for (final byte in data) {
      bits.append(byte, 8);
    }
    // Terminator (up to four zero bits, ISO §7.4.9), then zero bits to
    // the next codeword boundary and no further -- unlike EC/11 pad
    // codewords, extra zero fill here changes the symbol (QR_NOTES.md).
    final terminator = dataCapacityBits - bits.length;
    bits
      ..append(0, terminator < 4 ? terminator : 4)
      ..append(0, (7 - (bits.length + 7) % 8));
    // Alternating pad codewords 0b11101100, 0b00010001 (ISO §7.4.10).
    var padByte = 0xEC;
    while (bits.length < dataCapacityBits) {
      bits.append(padByte, 8);
      padByte = padByte == 0xEC ? 0x11 : 0xEC;
    }
    return _interleave(bits.toBytes(), version, level);
  }

  /// Splits data codewords into ISO Table 9 blocks, computes each block's
  /// ECC and interleaves data then ECC column-wise (ISO §7.6).
  static Uint8List _interleave(
    Uint8List dataCodewords,
    int version,
    UqpayQrErrorCorrection level,
  ) {
    final numBlocks = _numEccBlocks[level.index][version - 1];
    final eccPerBlock = _eccCodewordsPerBlock[level.index][version - 1];
    final shortLength = dataCodewords.length ~/ numBlocks;
    final numLongBlocks = dataCodewords.length % numBlocks;
    final rs = _ReedSolomon(eccPerBlock);

    final blocks = <Uint8List>[];
    final eccBlocks = <Uint8List>[];
    var offset = 0;
    for (var b = 0; b < numBlocks; b++) {
      // Shorter blocks come first (ISO §7.5.2).
      final length = shortLength + (b < numBlocks - numLongBlocks ? 0 : 1);
      final block = dataCodewords.sublist(offset, offset + length);
      offset += length;
      blocks.add(block);
      eccBlocks.add(rs.eccFor(block));
    }

    final result = Uint8List(
      dataCodewords.length + eccPerBlock * numBlocks,
    );
    var i = 0;
    final longLength = shortLength + (numLongBlocks == 0 ? 0 : 1);
    for (var column = 0; column < longLength; column++) {
      for (final block in blocks) {
        if (column < block.length) {
          result[i++] = block[column];
        }
      }
    }
    for (var column = 0; column < eccPerBlock; column++) {
      for (final ecc in eccBlocks) {
        result[i++] = ecc[column];
      }
    }
    return result;
  }

  /// ECC codewords per block, indexed `[level.index][version - 1]` with
  /// levels in L, M, Q, H order (ISO/IEC 18004:2015 Table 9; verified
  /// entry-by-entry against segno 1.6.6).
  static const List<List<int>> _eccCodewordsPerBlock = [
    // L
    [
      7, 10, 15, 20, 26, 18, 20, 24, 30, 18, //
      20, 24, 26, 30, 22, 24, 28, 30, 28, 28, //
      28, 28, 30, 30, 26, 28, 30, 30, 30, 30, //
      30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
    ],
    // M
    [
      10, 16, 26, 18, 24, 16, 18, 22, 22, 26, //
      30, 22, 22, 24, 24, 28, 28, 26, 26, 26, //
      26, 28, 28, 28, 28, 28, 28, 28, 28, 28, //
      28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    ],
    // Q
    [
      13, 22, 18, 26, 18, 24, 18, 22, 20, 24, //
      28, 26, 24, 20, 30, 24, 28, 28, 26, 30, //
      28, 30, 30, 30, 30, 28, 30, 30, 30, 30, //
      30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
    ],
    // H
    [
      17, 28, 22, 16, 22, 28, 26, 26, 24, 28, //
      24, 28, 22, 24, 24, 30, 28, 28, 26, 28, //
      30, 24, 30, 30, 30, 30, 30, 30, 30, 30, //
      30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
    ],
  ];

  /// Number of error-correction blocks, indexed like
  /// [_eccCodewordsPerBlock] (ISO Table 9; verified against segno 1.6.6).
  static const List<List<int>> _numEccBlocks = [
    // L
    [
      1, 1, 1, 1, 1, 2, 2, 2, 2, 4, //
      4, 4, 4, 4, 6, 6, 6, 6, 7, 8, //
      8, 9, 9, 10, 12, 12, 12, 13, 14, 15, //
      16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
    ],
    // M
    [
      1, 1, 1, 2, 2, 4, 4, 4, 5, 5, //
      5, 8, 9, 9, 10, 10, 11, 13, 14, 16, //
      17, 17, 18, 20, 21, 23, 25, 26, 28, 29, //
      31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
    ],
    // Q
    [
      1, 1, 2, 2, 4, 4, 6, 6, 8, 8, //
      8, 10, 12, 16, 12, 17, 16, 18, 21, 20, //
      23, 23, 25, 27, 29, 34, 34, 35, 38, 40, //
      43, 45, 48, 51, 53, 56, 59, 62, 65, 68,
    ],
    // H
    [
      1, 1, 2, 4, 4, 4, 5, 6, 8, 8, //
      11, 11, 16, 16, 18, 16, 19, 21, 25, 25, //
      25, 34, 30, 32, 35, 37, 40, 42, 45, 48, //
      51, 54, 57, 60, 63, 66, 70, 74, 77, 81,
    ],
  ];
}

/// An append-only MSB-first bit buffer.
class _BitBuffer {
  final List<int> _bits = [];

  int get length => _bits.length;

  /// Appends the [count] low bits of [value], most significant first.
  void append(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _bits.add((value >> i) & 1);
    }
  }

  Uint8List toBytes() {
    assert(_bits.length % 8 == 0, 'bit buffer not codeword-aligned');
    final bytes = Uint8List(_bits.length ~/ 8);
    for (var i = 0; i < _bits.length; i++) {
      bytes[i >> 3] |= _bits[i] << (7 - (i & 7));
    }
    return bytes;
  }
}

/// Reed–Solomon ECC generator over GF(2^8) with the QR primitive
/// polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D) and generator roots
/// alpha^0 .. alpha^(degree-1) (ISO/IEC 18004:2015 §7.5.2, Annex A).
class _ReedSolomon {
  _ReedSolomon(this.degree)
    : assert(degree >= 1 && degree <= 30, 'unsupported ECC degree') {
    // Build the generator polynomial: product of (x - alpha^i).
    _generator = Uint8List(degree)..[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      // Multiply the current product by (x - alpha^i).
      for (var j = 0; j < degree; j++) {
        _generator[j] = _multiply(_generator[j], root);
        if (j + 1 < degree) {
          _generator[j] ^= _generator[j + 1];
        }
      }
      root = _multiply(root, 0x02);
    }
  }

  /// The number of ECC codewords produced per block.
  final int degree;

  late final Uint8List _generator;

  /// Returns the [degree] ECC codewords for [data] (polynomial remainder).
  Uint8List eccFor(Uint8List data) {
    final result = Uint8List(degree);
    for (final byte in data) {
      final factor = byte ^ result[0];
      result.setRange(0, degree - 1, result, 1);
      result[degree - 1] = 0;
      for (var j = 0; j < degree; j++) {
        result[j] ^= _multiply(_generator[j], factor);
      }
    }
    return result;
  }

  /// Carry-less GF(2^8) product reduced by 0x11D.
  static int _multiply(int a, int b) {
    var product = 0;
    for (var i = 7; i >= 0; i--) {
      product = (product << 1) ^ ((product >> 7) * 0x11D);
      product ^= ((b >> i) & 1) * a;
    }
    assert(product >> 8 == 0, 'GF(256) product out of range');
    return product;
  }
}

/// Places function patterns and codewords into the module grid, applies
/// data masking and format/version information (ISO §7.7–7.10).
class _QrModulePlacer {
  _QrModulePlacer(this.version, this.level)
    : size = 17 + 4 * version,
      _modules = List<bool>.filled(
        (17 + 4 * version) * (17 + 4 * version),
        false,
      ),
      _isFunction = List<bool>.filled(
        (17 + 4 * version) * (17 + 4 * version),
        false,
      );

  final int version;
  final UqpayQrErrorCorrection level;
  final int size;
  final List<bool> _modules;
  final List<bool> _isFunction;

  bool _get(int x, int y) => _modules[y * size + x];

  void _set(int x, int y, {required bool dark}) =>
      _modules[y * size + x] = dark;

  void _setFunction(int x, int y, {required bool dark}) {
    _modules[y * size + x] = dark;
    _isFunction[y * size + x] = true;
  }

  /// Runs the full placement pipeline and returns the finished matrix.
  UqpayQrMatrix place(Uint8List codewords, {int? forcedMask}) {
    _drawFunctionPatterns();
    _drawCodewords(codewords);
    final mask = forcedMask ?? _selectBestMask();
    _applyMask(mask);
    // Format and version information are written only after the mask is
    // chosen: the ISO §7.8.3 evaluation is performed with those areas
    // held light (see _selectBestMask).
    _drawFormatBits(mask);
    _drawVersionBits();
    return UqpayQrMatrix(
      version: version,
      errorCorrection: level,
      maskPattern: mask,
      modules: _modules,
    );
  }

  void _drawFunctionPatterns() {
    // Reserve the format areas, the dark module and (v7+) the version
    // areas as light function modules first. They keep that state through
    // mask evaluation and receive their real bits afterwards, so the
    // §7.8.3 penalty comparison sees them light — the reading of the
    // spec that segno (this encoder's conformance reference) uses.
    for (var i = 0; i < 9; i++) {
      _setFunction(8, i, dark: false);
      _setFunction(i, 8, dark: false);
    }
    for (var i = 1; i <= 8; i++) {
      _setFunction(size - i, 8, dark: false);
      _setFunction(8, size - i, dark: false);
    }
    if (version >= 7) {
      for (var i = 0; i < 18; i++) {
        _setFunction(size - 11 + i % 3, i ~/ 3, dark: false);
        _setFunction(i ~/ 3, size - 11 + i % 3, dark: false);
      }
    }
    // Timing patterns (ISO §6.3.5).
    for (var i = 0; i < size; i++) {
      _setFunction(6, i, dark: i.isEven);
      _setFunction(i, 6, dark: i.isEven);
    }
    // Finder patterns with separators (ISO §6.3.3-6.3.4).
    _drawFinderPattern(3, 3);
    _drawFinderPattern(size - 4, 3);
    _drawFinderPattern(3, size - 4);
    // Alignment patterns (ISO §6.3.6, Annex E).
    final centers = _alignmentPatternCenters[version - 1];
    final last = centers.length - 1;
    for (var i = 0; i <= last; i++) {
      for (var j = 0; j <= last; j++) {
        final overlapsFinder =
            (i == 0 && j == 0) ||
            (i == 0 && j == last) ||
            (i == last && j == 0);
        if (!overlapsFinder) {
          _drawAlignmentPattern(centers[i], centers[j]);
        }
      }
    }
  }

  void _drawFinderPattern(int cx, int cy) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final x = cx + dx;
        final y = cy + dy;
        if (x >= 0 && x < size && y >= 0 && y < size) {
          final distance = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
          _setFunction(x, y, dark: distance != 2 && distance != 4);
        }
      }
    }
  }

  void _drawAlignmentPattern(int cx, int cy) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final distance = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        _setFunction(cx + dx, cy + dy, dark: distance != 1);
      }
    }
  }

  /// Writes both copies of the 15-bit format information for [mask]
  /// (ISO §7.9): 5 data bits (level + mask), BCH(15,5) remainder with
  /// generator 0x537, XOR-masked with 0x5412, plus the dark module.
  void _drawFormatBits(int mask) {
    final data = level.formatBits << 3 | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = (data << 10 | rem) ^ 0x5412;
    assert(bits >> 15 == 0, 'format info out of range');

    bool bit(int i) => (bits >> i) & 1 != 0;
    // First copy, around the top-left finder.
    for (var i = 0; i <= 5; i++) {
      _setFunction(8, i, dark: bit(i));
    }
    _setFunction(8, 7, dark: bit(6));
    _setFunction(8, 8, dark: bit(7));
    _setFunction(7, 8, dark: bit(8));
    for (var i = 9; i < 15; i++) {
      _setFunction(14 - i, 8, dark: bit(i));
    }
    // Second copy, split between the other two finders.
    for (var i = 0; i <= 7; i++) {
      _setFunction(size - 1 - i, 8, dark: bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _setFunction(8, size - 15 + i, dark: bit(i));
    }
    // Dark module (ISO §7.9.1).
    _setFunction(8, size - 8, dark: true);
  }

  /// Draws both 18-bit version-information blocks for version 7 and above
  /// (ISO §7.10): 6 version bits + BCH(18,6) remainder, generator 0x1F25.
  void _drawVersionBits() {
    if (version < 7) {
      return;
    }
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = version << 12 | rem;
    assert(bits >> 18 == 0, 'version info out of range');
    for (var i = 0; i < 18; i++) {
      final bit = (bits >> i) & 1 != 0;
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      _setFunction(a, b, dark: bit);
      _setFunction(b, a, dark: bit);
    }
  }

  /// Places codeword bits in the zig-zag order of ISO §7.7.3: two-module
  /// columns from the right edge, alternating upward and downward, and
  /// skipping the vertical timing column. Any leftover remainder modules
  /// stay light.
  void _drawCodewords(Uint8List codewords) {
    var bitIndex = 0;
    final totalBits = codewords.length * 8;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) {
        right = 5;
      }
      for (var vertical = 0; vertical < size; vertical++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = (right + 1) & 2 == 0;
          final y = upward ? size - 1 - vertical : vertical;
          if (!_isFunction[y * size + x] && bitIndex < totalBits) {
            _set(
              x,
              y,
              dark: (codewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1 != 0,
            );
            bitIndex++;
          }
        }
      }
    }
    assert(bitIndex == totalBits, 'codewords did not fill the data region');
  }

  /// The ISO §7.8.2 data-mask condition for pattern [mask] at column [x],
  /// row [y]: the module is inverted when the condition holds.
  static bool _maskBit(int mask, int x, int y) => switch (mask) {
    0 => (x + y).isEven,
    1 => y.isEven,
    2 => x % 3 == 0,
    3 => (x + y) % 3 == 0,
    4 => (x ~/ 3 + y ~/ 2).isEven,
    5 => x * y % 2 + x * y % 3 == 0,
    6 => (x * y % 2 + x * y % 3).isEven,
    7 => ((x + y) % 2 + x * y % 3).isEven,
    _ => throw ArgumentError.value(mask, 'mask', 'must be 0..7'),
  };

  /// XORs mask pattern [mask] over the non-function modules. Applying the
  /// same mask twice restores the original grid.
  void _applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (!_isFunction[y * size + x] && _maskBit(mask, x, y)) {
          _modules[y * size + x] = !_modules[y * size + x];
        }
      }
    }
  }

  /// Evaluates all eight masks with the ISO §7.8.3 penalty rules and
  /// returns the mask with the lowest score; ties break to the lowest
  /// pattern number. The format/version areas stay light during the
  /// comparison (they are written after selection), matching the segno
  /// reference implementation this encoder is verified against.
  int _selectBestMask() {
    var bestMask = 0;
    var bestPenalty = 1 << 32;
    for (var mask = 0; mask < 8; mask++) {
      _applyMask(mask);
      final penalty = _penaltyScore();
      if (penalty < bestPenalty) {
        bestPenalty = penalty;
        bestMask = mask;
      }
      _applyMask(mask); // Undo: XOR is its own inverse.
    }
    return bestMask;
  }

  /// The four penalty rules of ISO §7.8.3.1 (N1=3, N2=3, N3=40, N4=10).
  int _penaltyScore() {
    var penalty = 0;
    // Rules 1 and 3, rows and columns.
    for (var i = 0; i < size; i++) {
      penalty += _linePenalty((j) => _get(j, i)); // Row i.
      penalty += _linePenalty((j) => _get(i, j)); // Column i.
    }
    // Rule 2: 2x2 blocks of a single colour.
    for (var y = 0; y + 1 < size; y++) {
      for (var x = 0; x + 1 < size; x++) {
        final color = _get(x, y);
        if (color == _get(x + 1, y) &&
            color == _get(x, y + 1) &&
            color == _get(x + 1, y + 1)) {
          penalty += 3;
        }
      }
    }
    // Rule 4: dark-module proportion, 10 points per 5% step away from
    // 50% (|2*dark - total| * 10 / total == floor(|percent - 50| / 5)).
    var dark = 0;
    for (final isDark in _modules) {
      if (isDark) {
        dark++;
      }
    }
    final total = size * size;
    return penalty + (2 * dark - total).abs() * 10 ~/ total * 10;
  }

  /// Rule 1 along a single row/column accessed through [moduleAt]: each
  /// run of five same-coloured modules scores 3, plus 1 per extra module.
  /// Rule 3 for the same line is added via [_finderLikePenalty].
  int _linePenalty(bool Function(int index) moduleAt) {
    var penalty = 0;
    var runColor = moduleAt(0);
    var runLength = 1;
    for (var i = 1; i <= size; i++) {
      if (i < size && moduleAt(i) == runColor) {
        runLength++;
        continue;
      }
      if (runLength >= 5) {
        penalty += 3 + (runLength - 5);
      }
      if (i < size) {
        runColor = !runColor;
        runLength = 1;
      }
    }
    return penalty + _finderLikePenalty(moduleAt);
  }

  /// Counts ISO rule-3 finder-like occurrences on one line: the module
  /// sequence dark-light-dark-dark-dark-light-dark (1:1:3:1:1) preceded
  /// or followed by a light area four modules wide, 40 points each. A
  /// light run cut short by the edge of the symbol qualifies, because
  /// the quiet zone continues it. Scanning resumes after a counted
  /// pattern, or from its centre after a rejected one, exactly like the
  /// segno reference implementation.
  int _finderLikePenalty(bool Function(int index) moduleAt) {
    var penalty = 0;
    var i = 0;
    while (i + 7 <= size) {
      final isCore =
          moduleAt(i) &&
          !moduleAt(i + 1) &&
          moduleAt(i + 2) &&
          moduleAt(i + 3) &&
          moduleAt(i + 4) &&
          !moduleAt(i + 5) &&
          moduleAt(i + 6);
      if (!isCore) {
        i++;
        continue;
      }
      var qualifies = i == 0 || i == size - 7;
      if (!qualifies) {
        var allLight = true;
        for (var j = i - 4 > 0 ? i - 4 : 0; j < i; j++) {
          if (moduleAt(j)) {
            allLight = false;
            break;
          }
        }
        qualifies = allLight;
      }
      if (!qualifies) {
        var allLight = true;
        final end = i + 11 < size ? i + 11 : size;
        for (var j = i + 7; j < end; j++) {
          if (moduleAt(j)) {
            allLight = false;
            break;
          }
        }
        qualifies = allLight;
      }
      if (qualifies) {
        penalty += 40;
        i += 7;
      } else {
        i += 4;
      }
    }
    return penalty;
  }

  /// Alignment-pattern centre coordinates per version (ISO/IEC 18004:2015
  /// Annex E Table E.1; verified against segno 1.6.6).
  /// Index is `version - 1`.
  static const List<List<int>> _alignmentPatternCenters = [
    [],
    [6, 18],
    [6, 22],
    [6, 26],
    [6, 30],
    [6, 34],
    [6, 22, 38],
    [6, 24, 42],
    [6, 26, 46],
    [6, 28, 50],
    [6, 30, 54],
    [6, 32, 58],
    [6, 34, 62],
    [6, 26, 46, 66],
    [6, 26, 48, 70],
    [6, 26, 50, 74],
    [6, 30, 54, 78],
    [6, 30, 56, 82],
    [6, 30, 58, 86],
    [6, 34, 62, 90],
    [6, 28, 50, 72, 94],
    [6, 26, 50, 74, 98],
    [6, 30, 54, 78, 102],
    [6, 28, 54, 80, 106],
    [6, 32, 58, 84, 110],
    [6, 30, 58, 86, 114],
    [6, 34, 62, 90, 118],
    [6, 26, 50, 74, 98, 122],
    [6, 30, 54, 78, 102, 126],
    [6, 26, 52, 78, 104, 130],
    [6, 30, 56, 82, 108, 134],
    [6, 34, 60, 86, 112, 138],
    [6, 30, 58, 86, 114, 142],
    [6, 34, 62, 90, 118, 146],
    [6, 30, 54, 78, 102, 126, 150],
    [6, 24, 50, 76, 102, 128, 154],
    [6, 28, 54, 80, 106, 132, 158],
    [6, 32, 58, 84, 110, 136, 162],
    [6, 26, 54, 82, 110, 138, 166],
    [6, 30, 58, 86, 114, 142, 170],
  ];
}
