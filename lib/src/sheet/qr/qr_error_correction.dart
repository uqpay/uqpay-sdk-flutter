/// QR error-correction levels, ISO/IEC 18004:2015 §7.5.1 Table 9.
///
/// Each level trades payload capacity for scan robustness. The SDK renders
/// merchant-presented EMVCo payloads at [medium], the level EMVCo QCPS
/// recommends for merchant-presented QR and the industry default.
enum UqpayQrErrorCorrection {
  /// Level L — recovers ~7% of codewords.
  low(formatBits: 1),

  /// Level M — recovers ~15% of codewords. The SDK default.
  medium(formatBits: 0),

  /// Level Q — recovers ~25% of codewords.
  quartile(formatBits: 3),

  /// Level H — recovers ~30% of codewords.
  high(formatBits: 2),
  ;

  const UqpayQrErrorCorrection({required this.formatBits});

  /// The two-bit error-correction indicator placed in the format
  /// information (ISO/IEC 18004:2015 §7.9 Table 12): L=0b01, M=0b00,
  /// Q=0b11, H=0b10.
  final int formatBits;
}
