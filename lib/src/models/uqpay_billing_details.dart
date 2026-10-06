import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_address.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';

/// Billing details attached to a card (`payment_method.card.billing`).
/// Address verification (AVS) runs against [address].
///
/// For a **card** confirm the gateway requires [firstName], [lastName],
/// [email] and an [address] with `countryCode`, `city`, `street` and
/// `postcode`; `state` is required for some countries (US yes, SG no — the
/// gateway decides). A missing or empty field fails the confirm with
/// `invalid_payment_method` naming the field (`invalid billing.first_name`,
/// `invalid billing.last_name`, …), before any 3-D Secure step. Observed
/// against the sandbox.
///
/// `UqpayCardDetails` fills a missing [firstName] / [lastName] from the
/// cardholder name (see [withNamesFrom]), so a headless integration only
/// has to supply what the customer typed.
///
/// [toString] prints nothing identifying.
class UqpayBillingDetails extends UqpayJsonModel {
  /// Creates billing details. Unset fields are omitted from the wire body.
  const UqpayBillingDetails({
    this.firstName,
    this.lastName,
    this.email,
    this.phoneNumber,
    this.address,
  });

  /// Decodes a `billing` object. Never throws.
  factory UqpayBillingDetails.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final address = r.optionalObject('address');
    return UqpayBillingDetails(
      firstName: r.optionalString('first_name'),
      lastName: r.optionalString('last_name'),
      email: r.optionalString('email'),
      phoneNumber: r.optionalString('phone_number'),
      address: address == null ? null : UqpayAddress.fromJson(address),
    );
  }

  /// Cardholder first name.
  final String? firstName;

  /// Cardholder last name.
  final String? lastName;

  /// Contact email.
  final String? email;

  /// Contact phone number.
  final String? phoneNumber;

  /// Billing address (used for AVS).
  final UqpayAddress? address;

  /// Returns a copy whose missing [firstName] / [lastName] are derived from
  /// [cardholderName]: the text before the first space and the rest. A
  /// single-word name is used for both, because the gateway rejects an
  /// absent `last_name` outright and a repeated name is at least a valid
  /// request. Explicitly supplied names are never overwritten.
  UqpayBillingDetails withNamesFrom(String cardholderName) {
    if (firstName != null && lastName != null) {
      return this;
    }
    final name = cardholderName.trim();
    if (name.isEmpty) {
      return this;
    }
    final space = name.indexOf(' ');
    final first = space > 0 ? name.substring(0, space) : name;
    final last = space > 0 ? name.substring(space + 1).trim() : name;
    return UqpayBillingDetails(
      firstName: firstName ?? first,
      lastName: lastName ?? (last.isEmpty ? first : last),
      email: email,
      phoneNumber: phoneNumber,
      address: address,
    );
  }

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'first_name': firstName,
    'last_name': lastName,
    'email': email,
    'phone_number': phoneNumber,
    'address': address?.toJson(),
  });

  @override
  String toString() => 'UqpayBillingDetails(redacted)';
}
