/// Text-input formatters for the card form. Internal — never exported.
library;

import 'package:flutter/services.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_validation.dart';

/// The code points of `0` in the decimal-digit blocks a phone keyboard can
/// realistically emit (each block runs `0`..`9` contiguously): ASCII,
/// Arabic-Indic, Extended Arabic-Indic (Persian/Urdu), NKo, the Indic
/// scripts, Thai, Lao, Tibetan, Myanmar, Khmer, Mongolian and full-width.
const List<int> _digitZeros = <int>[
  0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, //
  0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0E50, 0x0ED0, 0x0F20, 0x1040, 0x17E0,
  0x1810, 0xFF10,
];

/// Strips [text] to its digits, as ASCII. Decimal digits from other scripts
/// (an Arabic-locale or full-width keypad) are converted rather than
/// silently dropped.
String digitsOf(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    for (final zero in _digitZeros) {
      if (rune >= zero && rune <= zero + 9) {
        buffer.writeCharCode(0x30 + rune - zero);
        break;
      }
    }
  }
  return buffer.toString();
}

/// Formats a PAN as it is typed: digits only, grouped with spaces per the
/// detected brand, capped at the brand's maximum length (19 for UnionPay —
/// never a hard 16).
class UqpayCardNumberFormatter extends TextInputFormatter {
  /// Creates the formatter.
  UqpayCardNumberFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = digitsOf(newValue.text);
    final brand = UqpayCardValidator.detectBrand(digits);
    final max = brand?.maxLength ?? UqpayCardValidator.maxPanLength;
    if (digits.length > max) {
      digits = digits.substring(0, max);
    }
    final grouped = UqpayCardValidator.groupNumber(digits, brand);

    // Keep the caret after the same count of digits it was after.
    final caretDigits = digitsOf(
      newValue.text.substring(
        0,
        newValue.selection.baseOffset.clamp(0, newValue.text.length),
      ),
    ).length;
    var offset = grouped.length;
    var seen = 0;
    for (var i = 0; i < grouped.length; i++) {
      if (seen == caretDigits) {
        offset = i;
        break;
      }
      if (grouped.codeUnitAt(i) != 0x20) {
        seen++;
      }
    }
    if (seen == caretDigits && caretDigits > 0) {
      offset = grouped.length;
    }
    return TextEditingValue(
      text: grouped,
      selection: TextSelection.collapsed(
        offset: offset.clamp(0, grouped.length),
      ),
    );
  }
}

/// Formats an expiry date as `MM/YY` while typing: digits only, a `0` is
/// auto-prefixed when the first digit can only be a single-digit month, and
/// the slash is inserted and removed automatically. A pasted or autofilled
/// value with a separator is read as month and year: `12/2030` becomes
/// `12/30` and `1/30` becomes `01/30`.
class UqpayExpiryDateFormatter extends TextInputFormatter {
  /// Creates the formatter.
  UqpayExpiryDateFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final split = _splitMonthYear(newValue.text);
    var digits = split ?? digitsOf(newValue.text);
    final deleting = newValue.text.length < oldValue.text.length;
    if (split == null && digits.length == 1 && !deleting) {
      final first = digits.codeUnitAt(0) - 0x30;
      if (first >= 2 && first <= 9) {
        digits = '0$digits';
      }
    }
    if (digits.length > 4) {
      digits = digits.substring(0, 4);
    }
    final text = digits.length <= 2
        ? digits
        : '${digits.substring(0, 2)}/${digits.substring(2)}';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  static final RegExp _separator = RegExp(r'\s*[/\-.]\s*');

  /// `MMYY` digits for a value typed or pasted with one month/year
  /// separator, or `null` when [text] has no separator (or more than one,
  /// or a month part that is not 1-2 digits) and is read as plain digits.
  static String? _splitMonthYear(String text) {
    final parts = text.trim().split(_separator);
    if (parts.length != 2) {
      return null;
    }
    final month = digitsOf(parts[0]);
    var year = digitsOf(parts[1]);
    if (month.isEmpty ||
        month.length > 2 ||
        month.length != parts[0].trim().length) {
      return null;
    }
    if (year.length == 4) {
      year = year.substring(2); // 2030 -> 30
    }
    return '${month.padLeft(2, '0')}$year';
  }
}

/// Digits-only formatter capped at [maxLength], for the CVC field.
class UqpayCvcFormatter extends TextInputFormatter {
  /// Creates the formatter.
  UqpayCvcFormatter({required this.maxLength});

  /// The longest accepted code (3, or 4 for American Express).
  final int maxLength;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = digitsOf(newValue.text);
    if (digits.length > maxLength) {
      digits = digits.substring(0, maxLength);
    }
    return TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
  }
}
