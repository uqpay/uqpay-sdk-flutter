import 'dart:math';

/// Generates a random (version 4, variant 1) UUID in **lowercase** canonical
/// form, e.g. `1b4e28ba-2fa1-4d3b-8c6e-9f0a1b2c3d4e`.
///
/// The server rejects uppercase idempotency keys, so the
/// generator produces lowercase directly rather than lowercasing afterwards.
/// Randomness comes from [Random.secure]; an in-house implementation keeps the
/// dependency tree small.
///
/// [random] is injectable for tests only; production callers leave it unset.
String generateUuidV4({Random? random}) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // RFC 4122 §4.4: version nibble = 4, variant bits = 10xx.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      hex.write('-');
    }
    hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

/// Matches a lowercase canonical UUID v4 string.
final RegExp lowercaseUuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
