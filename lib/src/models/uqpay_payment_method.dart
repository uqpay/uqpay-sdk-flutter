import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_billing_details.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';

/// 3-D Secure fields on a card as echoed by the server
/// (`payment_method.card.three_ds`) and, in the confirm
/// body, the optional `three_ds` object the sheet never populates
/// (the server drives 3DS through `next_action` instead).
class UqpayThreeDsData extends UqpayJsonModel {
  /// Creates 3-D Secure data. Unset fields are omitted from the wire body.
  const UqpayThreeDsData({
    this.returnUrl,
    this.acsResponse,
    this.deviceDataCollectionRes,
    this.dsTransactionId,
  });

  /// Decodes a `three_ds` object. Never throws.
  factory UqpayThreeDsData.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayThreeDsData(
      returnUrl: r.optionalString('return_url'),
      acsResponse: r.optionalString('acs_response'),
      deviceDataCollectionRes: r.optionalString('device_data_collection_res'),
      dsTransactionId: r.optionalString('ds_transaction_id'),
    );
  }

  /// Return URL for the challenge.
  final String? returnUrl;

  /// Access-control-server response.
  final String? acsResponse;

  /// Device data collection result.
  final String? deviceDataCollectionRes;

  /// Directory-server transaction id.
  final String? dsTransactionId;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'return_url': returnUrl,
    'acs_response': acsResponse,
    'device_data_collection_res': deviceDataCollectionRes,
    'ds_transaction_id': dsTransactionId,
  });
}

/// The card object the **server** echoes on a payment method
/// (`payment_method.card`). The card number here is
/// already masked by the server; the SDK never receives a full PAN back.
///
/// [toString] prints nothing identifying.
class UqpayCardPaymentMethod extends UqpayJsonModel {
  /// Creates a server-echoed card.
  const UqpayCardPaymentMethod({
    this.cardName,
    this.maskedCardNumber,
    this.network,
    this.billing,
    this.autoCapture,
    this.authorizationType,
    this.threeDsAction,
    this.threeDs,
  });

  /// Decodes a `card` object. Never throws.
  factory UqpayCardPaymentMethod.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final billing = r.optionalObject('billing');
    final threeDs = r.optionalObject('three_ds');
    return UqpayCardPaymentMethod(
      cardName: r.optionalString('card_name'),
      maskedCardNumber: r.optionalString('card_number'),
      network: r.optionalString('network'),
      billing: billing == null ? null : UqpayBillingDetails.fromJson(billing),
      autoCapture: r.optionalBool('auto_capture'),
      authorizationType: r.optionalString('authorization_type'),
      threeDsAction: r.optionalString('three_ds_action'),
      threeDs: threeDs == null ? null : UqpayThreeDsData.fromJson(threeDs),
    );
  }

  /// Cardholder name.
  final String? cardName;

  /// The card number as masked by the server (`card_number` on the wire).
  final String? maskedCardNumber;

  /// Card network, e.g. `visa`.
  final String? network;

  /// Billing details.
  final UqpayBillingDetails? billing;

  /// Whether the payment auto-captures.
  final bool? autoCapture;

  /// Authorisation type, e.g. `authorization`.
  final String? authorizationType;

  /// 3-D Secure action requested, e.g. `enforce_3ds`.
  final String? threeDsAction;

  /// 3-D Secure fields.
  final UqpayThreeDsData? threeDs;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'card_name': cardName,
    'card_number': maskedCardNumber,
    'network': network,
    'billing': billing?.toJson(),
    'auto_capture': autoCapture,
    'authorization_type': authorizationType,
    'three_ds_action': threeDsAction,
    'three_ds': threeDs?.toJson(),
  });

  @override
  String toString() => 'UqpayCardPaymentMethod(network: $network)';
}

/// The payment method attached to an intent (`payment_method`).
/// Only [type] is required on the wire.
class UqpayPaymentMethod extends UqpayJsonModel {
  /// Creates a payment method.
  const UqpayPaymentMethod({required this.type, this.card});

  /// Decodes a `payment_method` object. Throws [FormatException] only when
  /// `type` is missing.
  factory UqpayPaymentMethod.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final card = r.optionalObject('card');
    return UqpayPaymentMethod(
      type: r.requireString('type'),
      card: card == null ? null : UqpayCardPaymentMethod.fromJson(card),
    );
  }

  /// Method type string, e.g. `card`, `paynow`, `alipaycn`.
  final String type;

  /// Card details when [type] is `card`.
  final UqpayCardPaymentMethod? card;

  @override
  Map<String, Object?> toJson() =>
      jsonWithoutNulls(<String, Object?>{'type': type, 'card': card?.toJson()});

  @override
  String toString() => 'UqpayPaymentMethod(type: $type)';
}
