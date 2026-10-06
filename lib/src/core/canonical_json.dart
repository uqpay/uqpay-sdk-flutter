import 'dart:convert';

/// Encodes [value] as compact JSON with every object's keys sorted.
///
/// The server honours a replayed `x-idempotency-key` only for a
/// **byte-identical** body, so a confirm body re-encoded
/// on retry — possibly after a process restart, from a freshly built model —
/// must produce exactly the same bytes. Sorting keys recursively at every
/// nesting level (including inside lists) makes the encoding independent of
/// map insertion order.
///
/// Only JSON-representable values are accepted: `null`, `bool`, `int`,
/// `String`, `List`, and `Map<String, Object?>`. Doubles are rejected with an
/// [ArgumentError] because no wire field is a floating-point number
/// (amounts travel as strings) and their textual form is not stable across
/// platforms.
String encodeCanonicalJson(Object? value) => jsonEncode(_canonicalise(value));

Object? _canonicalise(Object? value) {
  switch (value) {
    case null || bool() || int() || String():
      return value;
    case double():
      throw ArgumentError.value(
        value,
        'value',
        'floating-point numbers are not part of the UQPAY wire contract and '
            'cannot be encoded canonically',
      );
    case Map<Object?, Object?>():
      final sortedKeys = value.keys.map((k) => k! as String).toList()..sort();
      return <String, Object?>{
        for (final key in sortedKeys) key: _canonicalise(value[key]),
      };
    case List<Object?>():
      return value.map(_canonicalise).toList(growable: false);
    default:
      throw ArgumentError.value(
        value,
        'value',
        'unsupported value type for canonical JSON; only null, bool, int, '
            'String, List and Map<String, Object?> are allowed',
      );
  }
}
