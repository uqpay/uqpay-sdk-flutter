import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_address.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';

/// The customer attached to a payment intent (`customer`).
///
/// [toString] prints nothing identifying.
class UqpayCustomer extends UqpayJsonModel {
  /// Creates a customer. Unset fields are omitted from the wire body.
  const UqpayCustomer({
    this.firstName,
    this.lastName,
    this.email,
    this.phoneNumber,
    this.description,
    this.address,
    this.metadata,
  });

  /// Decodes a `customer` object. Never throws.
  factory UqpayCustomer.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final address = r.optionalObject('address');
    return UqpayCustomer(
      firstName: r.optionalString('first_name'),
      lastName: r.optionalString('last_name'),
      email: r.optionalString('email'),
      phoneNumber: r.optionalString('phone_number'),
      description: r.optionalString('description'),
      address: address == null ? null : UqpayAddress.fromJson(address),
      metadata: r.optionalStringMap('metadata'),
    );
  }

  /// First name.
  final String? firstName;

  /// Last name.
  final String? lastName;

  /// Email address.
  final String? email;

  /// Phone number.
  final String? phoneNumber;

  /// Free-form description.
  final String? description;

  /// Postal address.
  final UqpayAddress? address;

  /// Free-form string→string metadata.
  final Map<String, String>? metadata;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'first_name': firstName,
    'last_name': lastName,
    'email': email,
    'phone_number': phoneNumber,
    'description': description,
    'address': address?.toJson(),
    'metadata': metadata,
  });

  @override
  String toString() => 'UqpayCustomer(redacted)';
}
