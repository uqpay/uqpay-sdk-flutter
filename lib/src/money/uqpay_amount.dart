import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// An exact monetary amount as the UQPAY API represents it: a decimal string
/// in **major units** such as `"8.98"`, `"100"` or `"1.500"`.
///
/// The wire string is parsed once into digits plus a scale and held exactly —
/// never as a `double`, never rescaled. [toWireString] reproduces the server's
/// string byte for byte, and [format] renders it for display through `intl`
/// using the value's own number of fraction digits. The SDK performs no
/// arithmetic on amounts at all; the currency exponent is a *formatting*
/// input, never a multiplier.
///
/// ```dart
/// final amount = UqpayAmount.parse('1234.50');
/// amount.toWireString();                       // "1234.50"
/// amount.format(currencyCode: 'USD', locale: 'en_US'); // "$1,234.50"
/// ```
///
/// Two amounts are equal when they denote the same number, so
/// `UqpayAmount.parse('1.5') == UqpayAmount.parse('1.50')`, even though their
/// wire strings differ.
@immutable
class UqpayAmount implements Comparable<UqpayAmount> {
  const UqpayAmount._({
    required BigInt magnitude,
    required this.scale,
    required this.isNegative,
  }) : _magnitude = magnitude;

  /// Parses a wire amount such as `"8.98"`.
  ///
  /// Accepts an optional leading `-`, an integer part with no leading zeros
  /// (other than a lone `0`), and an optional fraction with at least one
  /// digit. Rejects everything else — thousands separators, exponents,
  /// currency symbols, whitespace, a trailing `.` — with a [FormatException],
  /// because such a string cannot have come from the API and guessing at its
  /// meaning is how money bugs start.
  factory UqpayAmount.parse(String wire) {
    final amount = tryParse(wire);
    if (amount == null) {
      throw FormatException(
        'not a UQPAY wire amount; expected a decimal string in major units '
        'such as "8.98"',
        wire,
      );
    }
    return amount;
  }

  /// Like [UqpayAmount.parse] but returns `null` instead of throwing.
  static UqpayAmount? tryParse(String wire) {
    final match = _wirePattern.firstMatch(wire);
    if (match == null) {
      return null;
    }
    final isNegative = match.group(1) == '-';
    final integerPart = match.group(2)!;
    final fractionPart = match.group(3) ?? '';
    return UqpayAmount._(
      magnitude: BigInt.parse('$integerPart$fractionPart'),
      scale: fractionPart.length,
      isNegative: isNegative,
    );
  }

  /// `-?` then `0` or a no-leading-zero integer, then an optional fraction.
  static final RegExp _wirePattern = RegExp(
    r'^(-)?(0|[1-9][0-9]*)(?:\.([0-9]+))?$',
  );

  /// All the digits of the amount, without sign or decimal point, as one
  /// integer. `"12.34"` → `1234`; `"0.05"` → `5`.
  final BigInt _magnitude;

  /// The number of fraction digits the server sent. `"8.98"` → 2, `"100"` → 0,
  /// `"1.500"` → 3.
  ///
  /// This is the *value's* scale, which for a well-behaved server equals the
  /// currency's exponent. The SDK never rewrites it.
  final int scale;

  /// Whether the amount carries a leading minus sign.
  ///
  /// Payment-intent amounts are never negative; this exists so that the type
  /// can round-trip any value the API might legitimately send (for example a
  /// refund adjustment) without throwing.
  final bool isNegative;

  /// Whether the amount is exactly zero (regardless of scale or sign).
  bool get isZero => _magnitude == BigInt.zero;

  /// The digits before the decimal point, e.g. `"1234"` for `"1234.50"`.
  String get integerDigits => _split().$1;

  /// The digits after the decimal point, e.g. `"50"` for `"1234.50"`, or the
  /// empty string when [scale] is zero.
  String get fractionDigits => _split().$2;

  /// The amount exactly as it travels on the wire, e.g. `"8.98"`.
  ///
  /// For any string accepted by [UqpayAmount.parse] this is byte-identical to
  /// the input.
  String toWireString() {
    final (integer, fraction) = _split();
    final sign = isNegative ? '-' : '';
    return fraction.isEmpty ? '$sign$integer' : '$sign$integer.$fraction';
  }

  /// Renders the amount for display, e.g. `"$1,234.50"`, `"¥100"`,
  /// `"BD 1.500"`.
  ///
  /// Uses `intl`'s `NumberFormat.simpleCurrency` for the locale's grouping,
  /// decimal separator, digits and currency-symbol placement. The number of
  /// fraction digits shown is exactly [scale] — the digits the server sent —
  /// so the display can never disagree with the wire value. No rounding, no
  /// rescaling, no floating point: the integer part is formatted through
  /// `intl` and the fraction digits are spliced in verbatim.
  ///
  /// [locale] defaults to `Intl.defaultLocale` (or `en_US` when that is
  /// unset). An unknown locale falls back to `en_US` rather than throwing;
  /// display code must not fail a payment.
  ///
  /// [currencyCode] is an ISO 4217 code such as `USD`, `JPY` or `KWD`. It is
  /// used only to choose the symbol.
  String format({required String currencyCode, String? locale}) {
    final resolvedLocale = Intl.verifiedLocale(
      locale,
      NumberFormat.localeExists,
      onFailure: (_) => 'en_US',
    );
    final formatter = NumberFormat.simpleCurrency(
      locale: resolvedLocale,
      name: currencyCode,
      decimalDigits: scale,
    );

    final (integer, fraction) = _split();
    final integerValue = BigInt.parse(integer);
    // Format the (non-negative) integer part; intl emits `scale` zero
    // fraction digits which we then overwrite with the real fraction digits.
    // Astronomically large values (scale > 15, or an integer part beyond a
    // 64-bit int) and a locale pattern that does not place the zero run where
    // expected both fall back to the exact wire form: never lose digits,
    // never show a number we did not verify.
    final fits = scale <= 15 && integerValue.isValidInt;
    var text = fits ? formatter.format(integerValue.toInt()) : '';
    final zeroDigit = formatter.symbols.ZERO_DIGIT;
    final placeholder = formatter.symbols.DECIMAL_SEP + zeroDigit * scale;
    final index = fraction.isEmpty ? 0 : text.lastIndexOf(placeholder);
    if (!fits || index < 0) {
      return '$currencyCode ${toWireString()}';
    }
    if (fraction.isNotEmpty) {
      final localisedFraction = _localiseDigits(fraction, zeroDigit);
      text =
          text.substring(0, index) +
          formatter.symbols.DECIMAL_SEP +
          localisedFraction +
          text.substring(index + placeholder.length);
    }
    if (isNegative && !isZero) {
      text = '${formatter.symbols.MINUS_SIGN}$text';
    }
    return text;
  }

  static String _localiseDigits(String asciiDigits, String zeroDigit) {
    final offset = zeroDigit.codeUnitAt(0) - '0'.codeUnitAt(0);
    if (offset == 0) {
      return asciiDigits;
    }
    return String.fromCharCodes(asciiDigits.codeUnits.map((c) => c + offset));
  }

  (String, String) _split() {
    final digits = _magnitude.toString().padLeft(scale + 1, '0');
    final cut = digits.length - scale;
    return (digits.substring(0, cut), digits.substring(cut));
  }

  /// The magnitude re-expressed at [targetScale] fraction digits by
  /// zero-padding the digit string. Pure string manipulation — the SDK never
  /// multiplies an amount by a power of ten.
  BigInt _magnitudeAtScale(int targetScale) {
    assert(targetScale >= scale, 'never drop digits');
    return BigInt.parse('$_magnitude${'0' * (targetScale - scale)}');
  }

  @override
  int compareTo(UqpayAmount other) {
    final commonScale = scale > other.scale ? scale : other.scale;
    final a = _signed(_magnitudeAtScale(commonScale));
    final b = other._signed(other._magnitudeAtScale(commonScale));
    return a.compareTo(b);
  }

  BigInt _signed(BigInt magnitude) =>
      isNegative && magnitude != BigInt.zero ? -magnitude : magnitude;

  @override
  bool operator ==(Object other) =>
      other is UqpayAmount && compareTo(other) == 0;

  @override
  int get hashCode {
    if (isZero) {
      return 0;
    }
    // Strip trailing fraction zeros so 1.5 and 1.50 hash alike.
    var digits = _magnitude.toString();
    var trailing = 0;
    while (trailing < scale && digits.endsWith('0')) {
      digits = digits.substring(0, digits.length - 1);
      trailing++;
    }
    return Object.hash(digits, scale - trailing, isNegative && !isZero);
  }

  @override
  String toString() => toWireString();
}
