/// Card-number, expiry and CVC validation for the sheet's card form
/// (fully covered by tests; internal — never exported). Brand detection
/// itself is public API: [UqpayCardBrand].
///
/// Pure functions over digit strings: no widget types, no clock reads (the
/// caller passes "now" in), and no card value ever appears in a
/// return type that could reach a log.
library;

import 'package:uqpay_sdk_flutter/headless.dart';

/// How complete/valid a partially-typed value currently is.
enum UqpayCardFieldValidity {
  /// Too short to judge — keep typing, show no error yet.
  incomplete,

  /// Structurally wrong (failed Luhn, impossible month, …).
  invalid,

  /// The date is well-formed but in the past.
  expired,

  /// Complete and valid.
  valid,
}

/// Static card validation helpers. Internal.
abstract final class UqpayCardValidator {
  /// The absolute PAN input cap across all brands (ISO/IEC 7812).
  static const int maxPanLength = 19;

  /// Detects the scheme from the leading digits of [digits]; see
  /// [UqpayCardBrand.detect].
  static UqpayCardBrand? detectBrand(String digits) =>
      UqpayCardBrand.detect(digits);

  /// Whether [digits] passes the Luhn check (ISO/IEC 7812-1).
  static bool passesLuhn(String digits) {
    if (digits.isEmpty) {
      return false;
    }
    var sum = 0;
    var doubleIt = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      final code = digits.codeUnitAt(i) - 0x30;
      if (code < 0 || code > 9) {
        return false;
      }
      var d = code;
      if (doubleIt) {
        d += d;
        if (d > 9) {
          d -= 9;
        }
      }
      sum += d;
      doubleIt = !doubleIt;
    }
    return sum % 10 == 0;
  }

  /// Validates a PAN of [digits]: [UqpayCardFieldValidity.incomplete] while
  /// it may still become valid with more digits, `valid` when the length is
  /// complete for the (detected) brand **and** Luhn passes, `invalid`
  /// otherwise.
  static UqpayCardFieldValidity validateNumber(String digits) {
    if (digits.isEmpty) {
      return UqpayCardFieldValidity.incomplete;
    }
    final brand = detectBrand(digits);
    final lengths =
        brand?.validLengths ?? const [12, 13, 14, 15, 16, 17, 18, 19];
    final max = brand?.maxLength ?? maxPanLength;
    if (digits.length > max) {
      return UqpayCardFieldValidity.invalid;
    }
    if (lengths.contains(digits.length) && passesLuhn(digits)) {
      return UqpayCardFieldValidity.valid;
    }
    return digits.length < max
        ? UqpayCardFieldValidity.incomplete
        : UqpayCardFieldValidity.invalid;
  }

  /// Groups [digits] for display: 4-6-5 for American Express, 4-6-4 for
  /// 14-digit Diners Club, blocks of 4 otherwise.
  static String groupNumber(String digits, UqpayCardBrand? brand) {
    final groups = brand == UqpayCardBrand.amex
        ? const [4, 6, 5]
        : (brand == UqpayCardBrand.dinersClub && digits.length <= 14)
        ? const [4, 6, 4]
        : const [4, 4, 4, 4, 4];
    final buffer = StringBuffer();
    var index = 0;
    for (final group in groups) {
      if (index >= digits.length) {
        break;
      }
      if (index > 0) {
        buffer.write(' ');
      }
      final end = index + group > digits.length ? digits.length : index + group;
      buffer.write(digits.substring(index, end));
      index = end;
    }
    if (index < digits.length) {
      buffer
        ..write(' ')
        ..write(digits.substring(index));
    }
    return buffer.toString();
  }

  /// Validates an expiry typed as up to four digits (`MMYY`): rejects
  /// impossible months, and rejects any month before the month of [now]
  /// (F-UX: past-date rejection). The caller supplies [now] from the
  /// injected clock — this function never reads time itself.
  static UqpayCardFieldValidity validateExpiry(String mmyy, DateTime now) {
    if (mmyy.isEmpty) {
      return UqpayCardFieldValidity.incomplete;
    }
    final month0 = int.tryParse(mmyy.substring(0, 1));
    if (month0 == null) {
      return UqpayCardFieldValidity.invalid;
    }
    if (mmyy.length == 1) {
      return month0 <= 1
          ? UqpayCardFieldValidity.incomplete
          : UqpayCardFieldValidity.invalid;
    }
    final month = int.tryParse(mmyy.substring(0, 2));
    if (month == null || month < 1 || month > 12) {
      return UqpayCardFieldValidity.invalid;
    }
    if (mmyy.length < 4) {
      return UqpayCardFieldValidity.incomplete;
    }
    final year = int.tryParse(mmyy.substring(2, 4));
    if (year == null) {
      return UqpayCardFieldValidity.invalid;
    }
    final fullYear = 2000 + year;
    if (fullYear < now.year || (fullYear == now.year && month < now.month)) {
      return UqpayCardFieldValidity.expired;
    }
    return UqpayCardFieldValidity.valid;
  }

  /// Validates a CVC/CVV of [digits] against the (detected) [brand]:
  /// 4 digits for American Express, 3 otherwise; with no brand, 3 or 4.
  static UqpayCardFieldValidity validateCvc(
    String digits,
    UqpayCardBrand? brand,
  ) {
    if (digits.isEmpty) {
      return UqpayCardFieldValidity.incomplete;
    }
    final expected = brand?.cvcLength;
    if (expected != null) {
      if (digits.length == expected) {
        return UqpayCardFieldValidity.valid;
      }
      return digits.length < expected
          ? UqpayCardFieldValidity.incomplete
          : UqpayCardFieldValidity.invalid;
    }
    if (digits.length == 3 || digits.length == 4) {
      return UqpayCardFieldValidity.valid;
    }
    return digits.length < 3
        ? UqpayCardFieldValidity.incomplete
        : UqpayCardFieldValidity.invalid;
  }

  /// Validates a billing email address.
  ///
  /// The gateway requires `billing.email` on a card confirm and rejects the
  /// whole request with `invalid_payment_method: invalid billing.email` when
  /// it is absent or malformed, so this is a hard requirement rather than a
  /// nicety. The check is deliberately permissive — one `@`, a non-empty
  /// local part, and a dotted domain with a 2+ character last label — because
  /// a client that is stricter than the server rejects addresses that would
  /// have been accepted, and the server is the authority either way.
  static UqpayCardFieldValidity validateEmail(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return UqpayCardFieldValidity.incomplete;
    }
    if (trimmed.contains(' ')) {
      return UqpayCardFieldValidity.invalid;
    }
    final at = trimmed.indexOf('@');
    if (at <= 0 || at != trimmed.lastIndexOf('@') || at == trimmed.length - 1) {
      return UqpayCardFieldValidity.invalid;
    }
    final domain = trimmed.substring(at + 1);
    final labels = domain.split('.');
    if (labels.length < 2 || labels.any((label) => label.isEmpty)) {
      return UqpayCardFieldValidity.invalid;
    }
    return labels.last.length >= 2
        ? UqpayCardFieldValidity.valid
        : UqpayCardFieldValidity.invalid;
  }
}
