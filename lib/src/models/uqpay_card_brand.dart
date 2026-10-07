/// Card scheme detection from the PAN's leading digits (BIN ranges).
///
/// Pure functions over digit strings: no card value ever appears in a
/// return type that could reach a log. Lives in `models` so the
/// headless API can fill the gateway-required `network` field; the drop-in
/// sheet consumes it through the public barrel like any merchant would.
library;

/// A card scheme detected from the leading digits of a PAN (BIN range).
///
/// [wireName] is the exact `network` string the confirm body expects —
/// explicit, never derived from the enum's `name`. [displayName]
/// is the scheme's proper name, shown as-is: brand names are not
/// translated.
///
/// The gateway **requires** `payment_method.card.network` on a card confirm
/// and rejects the request with `invalid_payment_method: invalid card
/// network` when it is missing (observed against the sandbox).
/// `UqpayCardDetails` fills it from [detect] automatically; this type is
/// public so a headless integrator can show the brand, pick the CVC length
/// and cap the PAN input the same way the drop-in sheet does.
enum UqpayCardBrand {
  /// Visa: 13/16/19 digits, CVC 3.
  visa(
    wireName: 'visa',
    displayName: 'Visa',
    cvcLength: 3,
    validLengths: [13, 16, 19],
    maxLength: 19,
  ),

  /// Mastercard: 16 digits, CVC 3.
  mastercard(
    wireName: 'mastercard',
    displayName: 'Mastercard',
    cvcLength: 3,
    validLengths: [16],
    maxLength: 16,
  ),

  /// American Express: 15 digits, CVC 4.
  amex(
    wireName: 'amex',
    displayName: 'American Express',
    cvcLength: 4,
    validLengths: [15],
    maxLength: 15,
  ),

  /// Discover: 16–19 digits, CVC 3.
  discover(
    wireName: 'discover',
    displayName: 'Discover',
    cvcLength: 3,
    validLengths: [16, 17, 18, 19],
    maxLength: 19,
  ),

  /// JCB: 16–19 digits, CVC 3.
  jcb(
    wireName: 'jcb',
    displayName: 'JCB',
    cvcLength: 3,
    validLengths: [16, 17, 18, 19],
    maxLength: 19,
  ),

  /// Diners Club: 14–19 digits, CVC 3.
  dinersClub(
    wireName: 'dinersclub',
    displayName: 'Diners Club',
    cvcLength: 3,
    validLengths: [14, 15, 16, 17, 18, 19],
    maxLength: 19,
  ),

  /// UnionPay: 16–19 digits, CVC 3. **19-digit PANs are real and must be
  /// accepted** (an earlier native SDK capped input at 16 digits, a
  /// shipped bug).
  unionPay(
    wireName: 'unionpay',
    displayName: 'UnionPay',
    cvcLength: 3,
    validLengths: [16, 17, 18, 19],
    maxLength: 19,
  ),
  ;

  const UqpayCardBrand({
    required this.wireName,
    required this.displayName,
    required this.cvcLength,
    required this.validLengths,
    required this.maxLength,
  });

  /// The `network` value sent on the wire, e.g. `visa`.
  final String wireName;

  /// The brand's proper name, e.g. `Visa`.
  final String displayName;

  /// The security-code length this scheme uses (3, or 4 for Amex).
  final int cvcLength;

  /// PAN lengths that are complete for this scheme.
  final List<int> validLengths;

  /// The longest PAN this scheme issues — the input cap. UnionPay issues
  /// 19-digit PANs; capping at 16 was a defect seen in an earlier native SDK
  /// and locked those cards out.
  final int maxLength;

  /// Detects the scheme from the leading digits of [digits], or `null` when
  /// no range matches (or the string is empty).
  ///
  /// Range notes: UnionPay (62) is matched before Discover so the shared
  /// 622126–622925 range goes to UnionPay, matching how the cards are
  /// issued in UQPAY's markets.
  static UqpayCardBrand? detect(String digits) {
    if (digits.isEmpty) {
      return null;
    }
    if (digits.length == 1) {
      // One digit is only unambiguous for Visa; 3/5/6 each fan out to
      // several schemes and claiming one early would flash wrong badges.
      return digits == '4' ? UqpayCardBrand.visa : null;
    }
    if (digits.startsWith('34') || digits.startsWith('37')) {
      return UqpayCardBrand.amex;
    }
    if (digits.startsWith('62')) {
      return UqpayCardBrand.unionPay;
    }
    if (_inPrefixRange(digits, 300, 305) ||
        digits.startsWith('36') ||
        digits.startsWith('38') ||
        digits.startsWith('39')) {
      return UqpayCardBrand.dinersClub;
    }
    if (_inPrefixRange(digits, 3528, 3589)) {
      return UqpayCardBrand.jcb;
    }
    if (digits.startsWith('6011') ||
        digits.startsWith('65') ||
        _inPrefixRange(digits, 644, 649)) {
      return UqpayCardBrand.discover;
    }
    if (_inPrefixRange(digits, 51, 55) || _inPrefixRange(digits, 2221, 2720)) {
      return UqpayCardBrand.mastercard;
    }
    if (digits.startsWith('4')) {
      return UqpayCardBrand.visa;
    }
    return null;
  }

  /// Whether the leading digits of [digits] fall in the closed numeric
  /// prefix range [from]..[to] (both bounds have the same digit count).
  static bool _inPrefixRange(String digits, int from, int to) {
    final width = from.toString().length;
    if (digits.length < width) {
      // Not enough digits typed yet to decide; treat the partial prefix as
      // in range only if it could still complete into the range.
      final partial = int.tryParse(digits);
      if (partial == null) {
        return false;
      }
      final scale = width - digits.length;
      var lo = from;
      var hi = to;
      for (var i = 0; i < scale; i++) {
        lo ~/= 10;
        hi ~/= 10;
      }
      return partial >= lo && partial <= hi;
    }
    final prefix = int.tryParse(digits.substring(0, width));
    return prefix != null && prefix >= from && prefix <= to;
  }
}
