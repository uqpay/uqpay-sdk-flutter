import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';

/// The kind of customer action a [UqpayNextAction] asks for.
///
/// An **open value type** (not an enum): unknown wire values are preserved
/// with [isUnknown] `true`.
@immutable
class UqpayNextActionType {
  const UqpayNextActionType._(this.raw);

  /// Decodes a wire value. Never throws.
  factory UqpayNextActionType.fromRaw(String raw) => UqpayNextActionType._(raw);

  /// Open a URL (3-D Secure challenge, wallet redirect); the customer returns
  /// via the intent's `return_url`.
  static const UqpayNextActionType redirectToUrl = UqpayNextActionType._(
    'redirect_to_url',
  );

  /// Show a QR code for the customer to scan with a wallet app.
  static const UqpayNextActionType displayQrCode = UqpayNextActionType._(
    'display_qr_code',
  );

  /// Show bank-transfer details.
  static const UqpayNextActionType displayBankDetails = UqpayNextActionType._(
    'display_bank_details',
  );

  /// Load an HTML fragment that self-submits a POST form to the issuer's
  /// access-control server (3-D Secure device fingerprint / challenge).
  static const UqpayNextActionType redirectIframe = UqpayNextActionType._(
    'redirect_iframe',
  );

  /// Every type the SDK recognises.
  static const List<UqpayNextActionType> known = <UqpayNextActionType>[
    redirectToUrl,
    displayQrCode,
    displayBankDetails,
    redirectIframe,
  ];

  /// The exact wire value.
  final String raw;

  /// Whether the SDK does not recognise [raw].
  bool get isUnknown => !known.contains(this);

  @override
  bool operator ==(Object other) =>
      other is UqpayNextActionType && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UqpayNextActionType($raw)';
}

/// `next_action.redirect_to_url`. Both fields are
/// nullable — the iOS SDK's non-optional declaration made whole confirm
/// responses undecodable.
class UqpayRedirectToUrl extends UqpayJsonModel {
  /// Creates a redirect action.
  const UqpayRedirectToUrl({this.url, this.returnUrl});

  /// Decodes a `redirect_to_url` object. Never throws.
  factory UqpayRedirectToUrl.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayRedirectToUrl(
      url: r.optionalString('url'),
      returnUrl: r.optionalString('return_url'),
    );
  }

  /// The URL to open.
  final String? url;

  /// The merchant's return URL, echoed from the intent. Used by the SDK only
  /// as a navigation sentinel — its query string is never trusted.
  final String? returnUrl;

  @override
  Map<String, Object?> toJson() =>
      jsonWithoutNulls(<String, Object?>{'url': url, 'return_url': returnUrl});
}

/// `next_action.display_qr_code`.
///
/// Carries **both** QR representations: [qrCode] is a raw EMVCo payload to
/// render locally (PayNow et al.), [qrCodeUrl] is an image to download. The
/// iOS core model dropped [qrCode] and could not recover raw QRs.
class UqpayDisplayQrCode extends UqpayJsonModel {
  /// Creates a QR action.
  const UqpayDisplayQrCode({this.qrCode, this.qrCodeUrl, this.expiresAt});

  /// Decodes a `display_qr_code` object. Never throws.
  factory UqpayDisplayQrCode.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayDisplayQrCode(
      qrCode: r.optionalString('qr_code', emptyAsNull: true),
      qrCodeUrl: r.optionalString('qr_code_url', emptyAsNull: true),
      expiresAt: r.optionalString('expires_at', emptyAsNull: true),
    );
  }

  /// Raw EMVCo payload to encode into a QR image locally.
  final String? qrCode;

  /// HTTPS URL of a ready-made QR image.
  final String? qrCodeUrl;

  /// Expiry timestamp string as sent by the server.
  final String? expiresAt;

  /// Whether [qrCode] holds a raw payload to render locally rather than a
  /// URL. The wire heuristic: a value with no `://` is raw EMVCo.
  bool get hasRawPayload => qrCode != null && !qrCode!.contains('://');

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'qr_code': qrCode,
    'qr_code_url': qrCodeUrl,
    'expires_at': expiresAt,
  });
}

/// `next_action.display_bank_details`. All nullable.
class UqpayDisplayBankDetails extends UqpayJsonModel {
  /// Creates bank-transfer details.
  const UqpayDisplayBankDetails({
    this.bankName,
    this.accountNumber,
    this.routingNumber,
  });

  /// Decodes a `display_bank_details` object. Never throws.
  factory UqpayDisplayBankDetails.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayDisplayBankDetails(
      bankName: r.optionalString('bank_name'),
      accountNumber: r.optionalString('account_number'),
      routingNumber: r.optionalString('routing_number'),
    );
  }

  /// Receiving bank name.
  final String? bankName;

  /// Account number to transfer to.
  final String? accountNumber;

  /// Routing / branch number.
  final String? routingNumber;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'bank_name': bankName,
    'account_number': accountNumber,
    'routing_number': routingNumber,
  });
}

/// `next_action.redirect_iframe`: an HTML fragment with a
/// `method="POST"` form targeting the issuer's ACS. It must be loaded as HTML
/// and allowed to self-submit; rewriting it as a GET drops the POST body.
class UqpayRedirectIframe extends UqpayJsonModel {
  /// Creates an iframe action.
  const UqpayRedirectIframe({this.iframe});

  /// Decodes a `redirect_iframe` object. Never throws.
  factory UqpayRedirectIframe.fromJson(Map<String, Object?> json) =>
      UqpayRedirectIframe(iframe: JsonReader(json).optionalString('iframe'));

  /// The HTML fragment.
  final String? iframe;

  @override
  Map<String, Object?> toJson() =>
      jsonWithoutNulls(<String, Object?>{'iframe': iframe});
}

/// What the customer must do next (`next_action`).
///
/// The server sometimes omits `type`; [type] is then inferred from whichever
/// payload field is present, mirroring the iOS sheet's `actionType`
/// inference. [rawType] is the wire value when it was sent.
class UqpayNextAction extends UqpayJsonModel {
  /// Creates a next action.
  const UqpayNextAction({
    this.rawType,
    this.redirectToUrl,
    this.displayQrCode,
    this.displayBankDetails,
    this.redirectIframe,
  });

  /// Decodes a `next_action` object. Never throws.
  factory UqpayNextAction.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final redirect = r.optionalObject('redirect_to_url');
    final qr = r.optionalObject('display_qr_code');
    final bank = r.optionalObject('display_bank_details');
    final iframe = r.optionalObject('redirect_iframe');
    return UqpayNextAction(
      rawType: r.optionalString('type', emptyAsNull: true),
      redirectToUrl: redirect == null
          ? null
          : UqpayRedirectToUrl.fromJson(redirect),
      displayQrCode: qr == null ? null : UqpayDisplayQrCode.fromJson(qr),
      displayBankDetails: bank == null
          ? null
          : UqpayDisplayBankDetails.fromJson(bank),
      redirectIframe: iframe == null
          ? null
          : UqpayRedirectIframe.fromJson(iframe),
    );
  }

  /// The `type` field exactly as sent, or `null` when the server omitted it.
  final String? rawType;

  /// Present for [UqpayNextActionType.redirectToUrl].
  final UqpayRedirectToUrl? redirectToUrl;

  /// Present for [UqpayNextActionType.displayQrCode].
  final UqpayDisplayQrCode? displayQrCode;

  /// Present for [UqpayNextActionType.displayBankDetails].
  final UqpayDisplayBankDetails? displayBankDetails;

  /// Present for [UqpayNextActionType.redirectIframe].
  final UqpayRedirectIframe? redirectIframe;

  /// The effective action type: [rawType] when sent, otherwise inferred from
  /// the payload present, otherwise `null` when nothing is recognisable.
  UqpayNextActionType? get type {
    if (rawType != null) {
      return UqpayNextActionType.fromRaw(rawType!);
    }
    if (redirectToUrl != null) {
      return UqpayNextActionType.redirectToUrl;
    }
    if (displayQrCode != null) {
      return UqpayNextActionType.displayQrCode;
    }
    if (displayBankDetails != null) {
      return UqpayNextActionType.displayBankDetails;
    }
    if (redirectIframe != null) {
      return UqpayNextActionType.redirectIframe;
    }
    return null;
  }

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'type': rawType,
    'redirect_to_url': redirectToUrl?.toJson(),
    'display_qr_code': displayQrCode?.toJson(),
    'display_bank_details': displayBankDetails?.toJson(),
    'redirect_iframe': redirectIframe?.toJson(),
  });

  @override
  String toString() => 'UqpayNextAction(type: ${type?.raw})';
}
