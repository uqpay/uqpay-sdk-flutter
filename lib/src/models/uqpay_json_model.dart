import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/core/canonical_json.dart';

/// Base class for every typed wire model in the SDK.
///
/// Gives each model value equality and a hash derived from its canonical JSON
/// form, so two models decoded from the same wire object are equal and a
/// re-built confirm body compares equal to the original. Subclasses must be
/// immutable and implement [toJson] as a pure function of their fields.
///
/// [toString] deliberately prints **no field values**: models can carry a
/// cardholder name, a masked PAN or a card form, and the SDK forbids any of
/// that reaching a log. Subclasses that are safe to summarise override it.
@immutable
abstract class UqpayJsonModel {
  /// Const constructor for subclasses.
  const UqpayJsonModel();

  /// The wire representation with explicit snake_case keys. Fields that are
  /// unset are **absent** (not `null`), so an encoded body is byte-stable for
  /// idempotent replay.
  Map<String, Object?> toJson();

  /// [toJson] encoded with sorted keys — the exact bytes sent on the wire.
  String toCanonicalJson() => encodeCanonicalJson(toJson());

  @override
  bool operator ==(Object other) =>
      other is UqpayJsonModel &&
      other.runtimeType == runtimeType &&
      other.toCanonicalJson() == toCanonicalJson();

  @override
  int get hashCode => toCanonicalJson().hashCode;

  @override
  String toString() => '$runtimeType(…)';
}
