import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';

/// A postal address as it appears in billing details and on a customer.
///
/// Every field is optional on the wire. [countryCode] is ISO 3166-1 alpha-2
/// and should always come from an explicit picker in your UI, never be
/// guessed from free text.
class UqpayAddress extends UqpayJsonModel {
  /// Creates an address. Unset fields are omitted from the wire body.
  const UqpayAddress({
    this.countryCode,
    this.state,
    this.city,
    this.street,
    this.postcode,
  });

  /// Decodes an `address` object. Never throws.
  factory UqpayAddress.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayAddress(
      countryCode: r.optionalString('country_code'),
      state: r.optionalString('state'),
      city: r.optionalString('city'),
      street: r.optionalString('street'),
      postcode: r.optionalString('postcode'),
    );
  }

  /// ISO 3166-1 alpha-2 country code, e.g. `SG`.
  final String? countryCode;

  /// State, province or region.
  final String? state;

  /// City.
  final String? city;

  /// Street lines. When you collect two lines, join them with `", "` — that
  /// is the shape the API expects.
  final String? street;

  /// Postal code.
  final String? postcode;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'country_code': countryCode,
    'state': state,
    'city': city,
    'street': street,
    'postcode': postcode,
  });
}
