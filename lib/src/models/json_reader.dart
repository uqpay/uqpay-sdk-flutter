import 'package:uqpay_sdk_flutter/src/money/uqpay_amount.dart';

/// Lenient, typed readers over a decoded JSON object.
///
/// Every `fromJson` in the SDK reads through these helpers, which implement
/// the leniency the gateway's response contract asks for: a value of the wrong
/// JSON type is treated as absent rather than throwing, so a bookkeeping field
/// the server changes can never make a 2xx confirm response undecodable and
/// strand a genuinely-answered payment. Only the two identity fields of an
/// intent are required, and those callers use [requireString].
///
/// Empty strings are normalised to `null` where the contract says the API
/// sends `""` instead of omitting a field ([optionalString] with
/// `emptyAsNull`).
extension type const JsonReader(Map<String, Object?> json) {
  /// A string that must be present and non-empty. Throws [FormatException]
  /// naming [key] otherwise.
  String requireString(String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw FormatException('missing or invalid required field "$key"');
  }

  /// A string, or `null` when absent, not a string, or (when [emptyAsNull])
  /// empty.
  String? optionalString(String key, {bool emptyAsNull = false}) {
    final value = json[key];
    if (value is! String) {
      return null;
    }
    if (emptyAsNull && value.isEmpty) {
      return null;
    }
    return value;
  }

  /// A number-as-string amount parsed exactly, or `null`
  /// when absent or unparseable. A JSON integer is accepted verbatim; a JSON
  /// float is rejected because its text is not the server's text.
  UqpayAmount? optionalAmount(String key) {
    final value = json[key];
    return switch (value) {
      String() => UqpayAmount.tryParse(value),
      int() => UqpayAmount.tryParse(value.toString()),
      _ => null,
    };
  }

  /// A boolean, or `null` when absent or not a boolean.
  bool? optionalBool(String key) {
    final value = json[key];
    return value is bool ? value : null;
  }

  /// An integer, or `null` when absent or not an integer.
  int? optionalInt(String key) {
    final value = json[key];
    return value is int ? value : null;
  }

  /// A nested object, or `null` when absent or not an object.
  Map<String, Object?>? optionalObject(String key) {
    final value = json[key];
    return value is Map<String, Object?> ? value : null;
  }

  /// A list of strings (non-string elements dropped), or `null` when absent
  /// or not a list.
  List<String>? optionalStringList(String key) {
    final value = json[key];
    if (value is! List<Object?>) {
      return null;
    }
    return value.whereType<String>().toList(growable: false);
  }

  /// A string→string map (non-string values dropped), or `null` when absent
  /// or not an object.
  Map<String, String>? optionalStringMap(String key) {
    final value = json[key];
    if (value is! Map<String, Object?>) {
      return null;
    }
    return <String, String>{
      for (final entry in value.entries)
        if (entry.value is String) entry.key: entry.value! as String,
    };
  }
}

/// Builds a JSON object omitting every `null` value.
///
/// Absence rather than `null` is load-bearing on the wire: unset confirm
/// fields must be *absent* so a replayed body stays byte-identical.
Map<String, Object?> jsonWithoutNulls(Map<String, Object?> fields) =>
    <String, Object?>{
      for (final entry in fields.entries)
        if (entry.value != null) entry.key: entry.value,
    };
