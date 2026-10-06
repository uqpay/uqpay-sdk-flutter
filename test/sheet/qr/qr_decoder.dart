/// A minimal, test-only QR decoder written independently from the shipped
/// encoder, straight from ISO/IEC 18004:2015. It is the round-trip half of
/// the encoder correctness proof:
///
/// * format information is read from both copies, cross-checked, and
///   verified against the BCH(15,5) generator 0x537;
/// * version information (v7+) is verified against the BCH(18,6)
///   generator 0x1F25;
/// * alignment-pattern positions are **computed algorithmically**, not
///   taken from the encoder's Annex E table, so the two derivations
///   cross-check each other;
/// * the Reed-Solomon block structure comes from `segno_tables.dart`
///   (dumped from segno 1.6.6), not from the encoder's tables;
/// * every block's syndromes `c(alpha^i)` for `i = 0..ecc-1` must be zero,
///   which fails if the encoder's generator polynomials, GF arithmetic or
///   interleaving are wrong;
/// * padding is checked to be the spec's alternating 0xEC/0x11 sequence.
///
/// Throws [QrDecodeException] on any structural violation.
library;

import 'dart:convert';

import 'segno_tables.dart';

/// Failure raised when a matrix is not a valid byte-mode QR symbol.
class QrDecodeException implements Exception {
  /// Creates the failure with a diagnostic [message].
  QrDecodeException(this.message);

  /// What was violated.
  final String message;

  @override
  String toString() => 'QrDecodeException: $message';
}

/// Everything recovered from a decoded symbol.
class DecodedQr {
  /// Bundles the decoded fields.
  DecodedQr({
    required this.text,
    required this.version,
    required this.mask,
    required this.errorLevelBits,
    required this.dataCodewords,
  });

  /// The decoded byte-mode payload, UTF-8 interpreted.
  final String text;

  /// Symbol version derived from the module count.
  final int version;

  /// Mask pattern recovered from the format information.
  final int mask;

  /// The two error-correction indicator bits (L=1, M=0, Q=3, H=2).
  final int errorLevelBits;

  /// The de-interleaved data codewords (before ECC), for vector checks.
  final List<int> dataCodewords;
}

/// Decodes [grid] (`grid[y][x]`, `true` = dark, no quiet zone).
DecodedQr decodeQr(List<List<bool>> grid) {
  final size = grid.length;
  if (size < 21 || size > 177 || (size - 17) % 4 != 0) {
    throw QrDecodeException('invalid module count $size');
  }
  for (final row in grid) {
    if (row.length != size) {
      throw QrDecodeException('matrix is not square');
    }
  }
  final version = (size - 17) ~/ 4;
  bool at(int x, int y) => grid[y][x];

  // --- Format information (ISO/IEC 18004 7.9), both copies. ---
  var fmt1 = 0;
  var fmt2 = 0;
  void setBit1(int i, {required bool dark}) => fmt1 |= (dark ? 1 : 0) << i;
  void setBit2(int i, {required bool dark}) => fmt2 |= (dark ? 1 : 0) << i;
  for (var i = 0; i <= 5; i++) {
    setBit1(i, dark: at(8, i));
  }
  setBit1(6, dark: at(8, 7));
  setBit1(7, dark: at(8, 8));
  setBit1(8, dark: at(7, 8));
  for (var i = 9; i < 15; i++) {
    setBit1(i, dark: at(14 - i, 8));
  }
  for (var i = 0; i <= 7; i++) {
    setBit2(i, dark: at(size - 1 - i, 8));
  }
  for (var i = 8; i < 15; i++) {
    setBit2(i, dark: at(8, size - 15 + i));
  }
  if (fmt1 != fmt2) {
    throw QrDecodeException('format info copies disagree');
  }
  final formatCodeword = fmt1 ^ 0x5412;
  if (_polyRemainder(formatCodeword, 0x537, 15, 10) != 0) {
    throw QrDecodeException('format info fails BCH(15,5) check');
  }
  final formatData = formatCodeword >> 10;
  final errorLevelBits = formatData >> 3;
  final mask = formatData & 7;
  if (!at(8, size - 8)) {
    throw QrDecodeException('dark module is light');
  }

  // --- Version information (ISO/IEC 18004 7.10) for v7+. ---
  if (version >= 7) {
    var vbits = 0;
    for (var i = 0; i < 18; i++) {
      final dark = at(size - 11 + i % 3, i ~/ 3);
      vbits |= (dark ? 1 : 0) << i;
    }
    if (_polyRemainder(vbits, 0x1F25, 18, 12) != 0) {
      throw QrDecodeException('version info fails BCH(18,6) check');
    }
    if (vbits >> 12 != version) {
      throw QrDecodeException(
        'version info says ${vbits >> 12}, module count says $version',
      );
    }
  }

  // --- Function-module map, built from scratch. ---
  final isFunction = List<bool>.generate(
    size * size,
    (_) => false,
    growable: false,
  );
  void mark(int x, int y) => isFunction[y * size + x] = true;
  for (var i = 0; i < size; i++) {
    mark(6, i);
    mark(i, 6);
  }
  // Finders, separators, format areas and the dark module: a 9x9 block
  // top-left, an 8-wide x 9-tall block top-right, a 9-wide x 8-tall block
  // bottom-left (ISO/IEC 18004 6.3.3, 6.3.4, 7.9.1).
  for (var y = 0; y < 9; y++) {
    for (var x = 0; x < 9; x++) {
      mark(x, y);
      if (x < 8) {
        mark(size - 1 - x, y);
      }
      if (y < 8) {
        mark(x, size - 1 - y);
      }
    }
  }
  if (version >= 7) {
    for (var i = 0; i < 18; i++) {
      mark(size - 11 + i % 3, i ~/ 3);
      mark(i ~/ 3, size - 11 + i % 3);
    }
  }
  final centers = _alignmentCenters(version, size);
  final last = centers.length - 1;
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j <= last; j++) {
      final overlapsFinder =
          (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0);
      if (overlapsFinder) {
        continue;
      }
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          mark(centers[i] + dx, centers[j] + dy);
        }
      }
    }
  }

  // --- Unmask and read the codeword bit stream (ISO/IEC 18004 7.7.3, 7.8). ---
  final bits = <bool>[];
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) {
      right = 5;
    }
    for (var vertical = 0; vertical < size; vertical++) {
      for (var j = 0; j < 2; j++) {
        final x = right - j;
        final upward = (right + 1) & 2 == 0;
        final y = upward ? size - 1 - vertical : vertical;
        if (!isFunction[y * size + x]) {
          bits.add(at(x, y) ^ _maskBit(mask, x, y));
        }
      }
    }
  }
  final totalCodewords = bits.length ~/ 8;
  for (var i = totalCodewords * 8; i < bits.length; i++) {
    if (bits[i]) {
      throw QrDecodeException('remainder bit $i is not zero');
    }
  }
  final codewords = List<int>.generate(totalCodewords, (i) {
    var b = 0;
    for (var j = 0; j < 8; j++) {
      b = b << 1 | (bits[i * 8 + j] ? 1 : 0);
    }
    return b;
  }, growable: false);

  // --- De-interleave blocks (segno tables, not the encoder's). ---
  final levelIndex = const {1: 0, 0: 1, 3: 2, 2: 3}[errorLevelBits]!;
  final eccPerBlock = segnoEccCodewordsPerBlock[levelIndex][version - 1];
  final numBlocks = segnoNumEccBlocks[levelIndex][version - 1];
  final dataLength = totalCodewords - eccPerBlock * numBlocks;
  final shortLength = dataLength ~/ numBlocks;
  final numLongBlocks = dataLength % numBlocks;
  final blockLengths = List<int>.generate(
    numBlocks,
    (b) => shortLength + (b < numBlocks - numLongBlocks ? 0 : 1),
    growable: false,
  );
  final dataBlocks = [for (final n in blockLengths) List<int>.filled(n, 0)];
  final eccBlocks = [
    for (var b = 0; b < numBlocks; b++) List<int>.filled(eccPerBlock, 0),
  ];
  var pos = 0;
  final longLength = shortLength + (numLongBlocks == 0 ? 0 : 1);
  for (var column = 0; column < longLength; column++) {
    for (var b = 0; b < numBlocks; b++) {
      if (column < blockLengths[b]) {
        dataBlocks[b][column] = codewords[pos++];
      }
    }
  }
  for (var column = 0; column < eccPerBlock; column++) {
    for (var b = 0; b < numBlocks; b++) {
      eccBlocks[b][column] = codewords[pos++];
    }
  }
  if (pos != totalCodewords) {
    throw QrDecodeException('interleaving did not consume every codeword');
  }

  // --- Reed-Solomon syndrome check per block. ---
  final gf = _GaloisField();
  for (var b = 0; b < numBlocks; b++) {
    final block = [...dataBlocks[b], ...eccBlocks[b]];
    for (var i = 0; i < eccPerBlock; i++) {
      var acc = 0;
      final alphaI = gf.exp(i);
      for (final codeword in block) {
        acc = gf.multiply(acc, alphaI) ^ codeword;
      }
      if (acc != 0) {
        throw QrDecodeException('block $b: syndrome $i is nonzero');
      }
    }
  }

  // --- Parse the byte-mode segment (ISO/IEC 18004 7.4.5). ---
  final data = [for (final block in dataBlocks) ...block];
  var bitPos = 0;
  int read(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = value << 1 | ((data[bitPos >> 3] >> (7 - (bitPos & 7))) & 1);
      bitPos++;
    }
    return value;
  }

  final mode = read(4);
  if (mode != 4) {
    throw QrDecodeException('expected byte mode (0b0100), got $mode');
  }
  final count = read(version <= 9 ? 8 : 16);
  final payloadBytes = List<int>.generate(count, (_) => read(8));

  // --- Terminator + padding structure (ISO/IEC 18004 7.4.9-7.4.10). ---
  final capacityBits = dataLength * 8;
  final terminator = capacityBits - bitPos < 4 ? capacityBits - bitPos : 4;
  if (read(terminator) != 0) {
    throw QrDecodeException('terminator bits are not zero');
  }
  final fill = (8 - bitPos % 8) % 8;
  if (read(fill) != 0) {
    throw QrDecodeException('fill bits to the codeword boundary not zero');
  }
  var expectedPad = 0xEC;
  while (bitPos < capacityBits) {
    final pad = read(8);
    if (pad != expectedPad) {
      throw QrDecodeException('pad codeword $pad, expected $expectedPad');
    }
    expectedPad = expectedPad == 0xEC ? 0x11 : 0xEC;
  }

  return DecodedQr(
    text: utf8.decode(payloadBytes),
    version: version,
    mask: mask,
    errorLevelBits: errorLevelBits,
    dataCodewords: data,
  );
}

/// Remainder of the [width]-bit [value] divided by the BCH [generator] of
/// degree [degree], over GF(2). Zero for a valid codeword.
int _polyRemainder(int value, int generator, int width, int degree) {
  var rem = value;
  for (var i = width - 1; i >= degree; i--) {
    if ((rem >> i) & 1 != 0) {
      rem ^= generator << (i - degree);
    }
  }
  return rem;
}

/// Alignment-pattern centres computed with the closed-form step rule (as
/// used by Project Nayuki's QR generator), deliberately *not* the
/// encoder's Annex E lookup table.
List<int> _alignmentCenters(int version, int size) {
  if (version == 1) {
    return const [];
  }
  final numAlign = version ~/ 7 + 2;
  final step = version == 32
      ? 26
      : (version * 4 + numAlign * 2 + 1) ~/ (numAlign * 2 - 2) * 2;
  final result = <int>[];
  var position = size - 7;
  for (var i = 0; i < numAlign - 1; i++) {
    result.insert(0, position);
    position -= step;
  }
  return [6, ...result];
}

/// The ISO/IEC 18004 7.8.2 mask conditions, re-stated from the spec table.
bool _maskBit(int mask, int x, int y) => switch (mask) {
  0 => (x + y).isEven,
  1 => y.isEven,
  2 => x % 3 == 0,
  3 => (x + y) % 3 == 0,
  4 => (y ~/ 2 + x ~/ 3).isEven,
  5 => (x * y) % 2 + (x * y) % 3 == 0,
  6 => ((x * y) % 2 + (x * y) % 3).isEven,
  7 => (((x + y) % 2) + ((x * y) % 3)).isEven,
  _ => throw QrDecodeException('mask $mask out of range'),
};

/// GF(2^8) arithmetic via log/antilog tables over the QR primitive
/// polynomial 0x11D, built iteratively (independent of the encoder's
/// carry-less multiply).
class _GaloisField {
  _GaloisField() {
    var x = 1;
    for (var i = 0; i < 255; i++) {
      _exp[i] = x;
      _log[x] = i;
      x <<= 1;
      if (x & 0x100 != 0) {
        x ^= 0x11D;
      }
    }
  }

  final List<int> _exp = List<int>.filled(255, 0);
  final List<int> _log = List<int>.filled(256, 0);

  /// alpha^[power].
  int exp(int power) => _exp[power % 255];

  /// Product of [a] and [b] in the field.
  int multiply(int a, int b) =>
      a == 0 || b == 0 ? 0 : _exp[(_log[a] + _log[b]) % 255];
}
