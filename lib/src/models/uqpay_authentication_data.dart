import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';

/// 3-D Secure results attached to an attempt's authentication data
/// (`authentication_data.three_ds`). All fields optional.
class UqpayThreeDsResult extends UqpayJsonModel {
  /// Creates a 3-D Secure result.
  const UqpayThreeDsResult({
    this.threeDsVersion,
    this.cavv,
    this.eci,
    this.dsTransactionId,
    this.authenticationStatus,
    this.cancellationReason,
  });

  /// Decodes a `three_ds` object. Never throws.
  factory UqpayThreeDsResult.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayThreeDsResult(
      threeDsVersion: r.optionalString('three_ds_version'),
      cavv: r.optionalString('cavv'),
      eci: r.optionalString('eci'),
      dsTransactionId: r.optionalString('ds_transaction_id'),
      authenticationStatus: r.optionalString('three_ds_authentication_status'),
      cancellationReason: r.optionalString('three_ds_cancellation_reason'),
    );
  }

  /// Protocol version, e.g. `2.2.0`.
  final String? threeDsVersion;

  /// Cardholder authentication verification value.
  final String? cavv;

  /// Electronic commerce indicator.
  final String? eci;

  /// Directory-server transaction id.
  final String? dsTransactionId;

  /// Authentication status as reported by the directory server.
  final String? authenticationStatus;

  /// Why authentication was cancelled, when it was.
  final String? cancellationReason;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'three_ds_version': threeDsVersion,
    'cavv': cavv,
    'eci': eci,
    'ds_transaction_id': dsTransactionId,
    'three_ds_authentication_status': authenticationStatus,
    'three_ds_cancellation_reason': cancellationReason,
  });
}

/// CVV / AVS / 3-D Secure results for a payment attempt
/// (`authentication_data`).
class UqpayAuthenticationData extends UqpayJsonModel {
  /// Creates authentication data.
  const UqpayAuthenticationData({
    this.cvvResult,
    this.avsResult,
    this.threeDs,
  });

  /// Decodes an `authentication_data` object. Never throws.
  factory UqpayAuthenticationData.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final threeDs = r.optionalObject('three_ds');
    return UqpayAuthenticationData(
      cvvResult: r.optionalString('cvv_result'),
      avsResult: r.optionalString('avs_result'),
      threeDs: threeDs == null ? null : UqpayThreeDsResult.fromJson(threeDs),
    );
  }

  /// CVV check result code.
  final String? cvvResult;

  /// Address verification result code.
  final String? avsResult;

  /// 3-D Secure outcome.
  final UqpayThreeDsResult? threeDs;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'cvv_result': cvvResult,
    'avs_result': avsResult,
    'three_ds': threeDs?.toJson(),
  });
}
