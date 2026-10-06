import 'package:uqpay_sdk_flutter/src/models/json_reader.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_billing_details.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_card_brand.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_json_model.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_method.dart';

/// Card details for a confirm (`payment_method.card`).
///
/// Holds the full PAN and CVC in memory for the duration of the request and
/// nowhere else. [toString] prints only the network and the last four digits;
/// nothing in the SDK ever logs, persists or otherwise copies the other
/// fields.
///
/// Structural checks (digit strings, `MM`/`YYYY` shapes) throw
/// [ArgumentError] naming the field at construction time; Luhn, brand and CVC
/// length validation are the card form's job.
class UqpayCardDetails extends UqpayJsonModel {
  /// Creates card details.
  ///
  /// [expiryMonth] is two digits with leading zero (`"09"`); [expiryYear] is
  /// four digits (`"2027"`); [cardNumber] is 12–19 digits with no spaces;
  /// [cvc] is 3–4 digits.
  ///
  /// [network] is the lowercase brand the gateway expects: `visa`,
  /// `mastercard`, `amex`, `discover`, `jcb`, `dinersclub`, `unionpay`. The
  /// gateway **requires** it and rejects a confirm without one as
  /// `invalid_payment_method: invalid card network`, so when you leave it
  /// `null` the SDK detects it from the PAN with [UqpayCardBrand.detect].
  /// Only a PAN outside every known BIN range is sent without a `network`
  /// (the SDK never sends `"unknown"`).
  ///
  /// [billing] is also gateway-mandatory for a card: `firstName`,
  /// `lastName`, `email` plus `address.countryCode`, `city`, `street` and
  /// `postcode`, with `state` required for some countries (the gateway
  /// decides which — US yes, SG no). Empty strings are rejected the same as
  /// missing fields. A missing first or last name is filled from [cardName]
  /// ([UqpayBillingDetails.withNamesFrom]); everything else the drop-in
  /// sheet collects, and a headless integration must supply.
  UqpayCardDetails({
    required this.cardName,
    required this.cardNumber,
    required this.expiryMonth,
    required this.expiryYear,
    required this.cvc,
    required UqpayBillingDetails billing,
    String? network,
    this.autoCapture = true,
    this.authorizationType = 'authorization',
    this.threeDsAction = 'enforce_3ds',
    this.threeDs,
  }) : billing = billing.withNamesFrom(cardName),
       network = network ?? UqpayCardBrand.detect(cardNumber)?.wireName {
    _requireDigits('cardNumber', cardNumber, min: 12, max: 19);
    _requireDigits('expiryMonth', expiryMonth, min: 2, max: 2);
    _requireDigits('expiryYear', expiryYear, min: 4, max: 4);
    _requireDigits('cvc', cvc, min: 3, max: 4);
    if (cardName.trim().isEmpty) {
      throw ArgumentError.value('', 'cardName', 'must not be empty');
    }
    if (cardName.trim().length > maxCardNameLength) {
      throw ArgumentError.value(
        cardName.length,
        'cardName',
        'must be at most $maxCardNameLength characters (the gateway rejects '
            'longer names)',
      );
    }
  }

  /// Decodes a `card` request object. Throws [ArgumentError] on structurally
  /// invalid values, [FormatException] on missing required fields.
  factory UqpayCardDetails.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final billing = r.optionalObject('billing');
    final threeDs = r.optionalObject('three_ds');
    return UqpayCardDetails(
      cardName: r.requireString('card_name'),
      cardNumber: r.requireString('card_number'),
      expiryMonth: r.requireString('expiry_month'),
      expiryYear: r.requireString('expiry_year'),
      cvc: r.requireString('cvc'),
      network: r.optionalString('network'),
      billing: UqpayBillingDetails.fromJson(billing ?? const {}),
      autoCapture: r.optionalBool('auto_capture') ?? true,
      authorizationType:
          r.optionalString('authorization_type') ?? 'authorization',
      threeDsAction: r.optionalString('three_ds_action') ?? 'enforce_3ds',
      threeDs: threeDs == null ? null : UqpayThreeDsData.fromJson(threeDs),
    );
  }

  static final RegExp _digits = RegExp(r'^[0-9]+$');

  static void _requireDigits(
    String field,
    String value, {
    required int min,
    required int max,
  }) {
    if (!_digits.hasMatch(value) || value.length < min || value.length > max) {
      // Deliberately does not echo the value: it may be a PAN or CVC.
      throw ArgumentError.value(
        '<redacted>',
        field,
        'must be $min–$max digits'
            '${min == max ? '' : ' with no spaces or separators'}',
      );
    }
  }

  /// Cardholder name, `"First Last"`.
  final String cardName;

  /// Full card number, digits only.
  final String cardNumber;

  /// Expiry month, `"MM"` (a **string** on the wire).
  final String expiryMonth;

  /// Expiry year, `"YYYY"` (a **string** on the wire).
  final String expiryYear;

  /// Card verification code.
  final String cvc;

  /// Lowercase network sent on the wire: the value you passed, else the
  /// brand detected from the PAN, else `null` when no BIN range matched.
  final String? network;

  /// The longest cardholder name the gateway accepts (observed against
  /// the gateway: 128 accepted, 200 rejected).
  static const int maxCardNameLength = 128;

  /// Billing details; the address inside is what AVS checks.
  final UqpayBillingDetails billing;

  /// Whether to capture automatically. The sheet sends `true`.
  final bool autoCapture;

  /// Authorisation type. The sheet sends `"authorization"`.
  final String authorizationType;

  /// 3-D Secure policy. The sheet sends `"enforce_3ds"`.
  final String threeDsAction;

  /// Optional 3-D Secure fields. Normally absent — the server drives 3DS via
  /// `next_action`.
  final UqpayThreeDsData? threeDs;

  /// The last four digits, e.g. `"4242"` — the only part of the number that
  /// may ever appear in output.
  String get last4 => cardNumber.substring(cardNumber.length - 4);

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'card_name': cardName,
    'card_number': cardNumber,
    'expiry_month': expiryMonth,
    'expiry_year': expiryYear,
    'cvc': cvc,
    'network': network,
    'billing': billing.toJson(),
    'auto_capture': autoCapture,
    'authorization_type': authorizationType,
    'three_ds_action': threeDsAction,
    'three_ds': threeDs?.toJson(),
  });

  @override
  String toString() =>
      'UqpayCardDetails(network: $network, last4: $last4, cvc: ***)';
}

/// **Experimental.** Details for a wallet / QR method in a confirm
/// (`payment_method.<type>`).
///
/// The wire shape of most wallet request objects is *inferred* from the
/// response schema and has not been proven by a live confirm for every method
/// (still ambiguous). Treat this class as experimental until the sandbox
/// confirms each wallet; it may change in a minor release.
///
/// Field usage by [UqpayConfirmPaymentMethod.type]:
///
/// * `alipaycn`, `alipayhk`: `flow`, `os_type` (lowercase, e.g. `ios`),
///   `is_present`.
/// * `wechatpay`: `flow` (`qrcode` | `mobile_app` | `mobile_web` |
///   `mini_program` | `official_account`), `os_type`, `is_present`,
///   `open_id`.
/// * `unionpay`: `flow` (`qrcode` | `securepay`), `os_type`, `is_present`.
/// * `grabpay`: `flow`, `is_present`, `shopper_name`.
/// * `paynow`: `flow`, `is_present`.
/// * `truemoney`, `tng`, `gcash`, `dana`, `kakaopay`, `tosspay`, `naverpay`:
///   `flow`, `os_type`, `is_present` (inferred).
///
/// Note the wallet `os_type` is **lowercase** (`ios`) whereas
/// `browser_info.mobile.os_type` is uppercase (`IOS`) — copy exactly, do not
/// normalise.
class UqpayWalletDetails extends UqpayJsonModel {
  /// Creates wallet details. Unset optional fields are omitted from the body.
  const UqpayWalletDetails({
    this.flow = 'qrcode',
    this.isPresent = false,
    this.osType,
    this.openId,
    this.shopperName,
  });

  /// Decodes a wallet details object. Never throws.
  factory UqpayWalletDetails.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayWalletDetails(
      flow: r.optionalString('flow') ?? 'qrcode',
      isPresent: r.optionalBool('is_present') ?? false,
      osType: r.optionalString('os_type'),
      openId: r.optionalString('open_id'),
      shopperName: r.optionalString('shopper_name'),
    );
  }

  /// Payment flow, e.g. `qrcode`.
  final String flow;

  /// Whether the customer is physically present. The sheet sends `false`.
  final bool isPresent;

  /// Lowercase OS type, e.g. `ios`, `android`.
  final String? osType;

  /// WeChat open id (required for `mini_program`/`mobile_app`/
  /// `official_account` flows).
  final String? openId;

  /// Shopper name (GrabPay).
  final String? shopperName;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'flow': flow,
    'is_present': isPresent,
    'os_type': osType,
    'open_id': openId,
    'shopper_name': shopperName,
  });
}

/// The `payment_method` object of a confirm request:
/// a [type] plus exactly one details object under the JSON key named after
/// the type. Unset details are **absent**, not `null`.
class UqpayConfirmPaymentMethod extends UqpayJsonModel {
  const UqpayConfirmPaymentMethod._({
    required this.type,
    this.card,
    this.wallet,
  });

  /// A card confirm: `{"type":"card","card":{…}}`.
  const UqpayConfirmPaymentMethod.card(UqpayCardDetails details)
    : this._(type: 'card', card: details);

  /// **Experimental.** A wallet / QR confirm: `{"type":"<type>","<type>":{…}}`.
  /// See [UqpayWalletDetails] for the caveats. Throws [ArgumentError] when
  /// [type] is empty or `card`.
  factory UqpayConfirmPaymentMethod.wallet(
    String type,
    UqpayWalletDetails details,
  ) {
    if (type.isEmpty || type == 'card') {
      throw ArgumentError.value(
        type,
        'type',
        'must be a wallet method type such as "paynow"',
      );
    }
    return UqpayConfirmPaymentMethod._(type: type, wallet: details);
  }

  /// Decodes a confirm `payment_method` object. Throws [FormatException] when
  /// `type` is missing or the details object for it is absent.
  factory UqpayConfirmPaymentMethod.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final type = r.requireString('type');
    final details = r.optionalObject(type);
    if (details == null) {
      throw FormatException('missing details object "$type"');
    }
    return type == 'card'
        ? UqpayConfirmPaymentMethod.card(UqpayCardDetails.fromJson(details))
        : UqpayConfirmPaymentMethod.wallet(
            type,
            UqpayWalletDetails.fromJson(details),
          );
  }

  /// Method type string, e.g. `card`, `paynow`.
  final String type;

  /// Card details when [type] is `card`.
  final UqpayCardDetails? card;

  /// Wallet details when [type] is a wallet.
  final UqpayWalletDetails? wallet;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'type': type,
    if (card != null) 'card': card!.toJson(),
    if (wallet != null) type: wallet!.toJson(),
  });

  @override
  String toString() => 'UqpayConfirmPaymentMethod(type: $type)';
}

/// `browser_info.browser`.
class UqpayBrowserDetails extends UqpayJsonModel {
  /// Creates browser details. [javaEnabled] defaults to `false` — Java does
  /// not exist on phones and the SDK never fabricates device data.
  const UqpayBrowserDetails({
    required this.userAgent,
    this.javaEnabled = false,
    this.javascriptEnabled = true,
    this.cookieEnabled = true,
    this.plugins = const <String>[],
    this.doNotTrack = false,
  });

  /// Decodes a `browser` object. Throws [FormatException] when `user_agent`
  /// is missing.
  factory UqpayBrowserDetails.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayBrowserDetails(
      userAgent: r.requireString('user_agent'),
      javaEnabled: r.optionalBool('java_enabled') ?? false,
      javascriptEnabled: r.optionalBool('javascript_enabled') ?? true,
      cookieEnabled: r.optionalBool('cookie_enabled') ?? true,
      plugins: r.optionalStringList('plugins') ?? const <String>[],
      doNotTrack: r.optionalBool('do_not_track') ?? false,
    );
  }

  /// A user agent describing the paying device.
  final String userAgent;

  /// Whether Java is enabled.
  final bool javaEnabled;

  /// Whether JavaScript is enabled.
  final bool javascriptEnabled;

  /// Whether cookies are enabled.
  final bool cookieEnabled;

  /// Browser plugins.
  final List<String> plugins;

  /// Do-not-track preference.
  final bool doNotTrack;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'user_agent': userAgent,
    'java_enabled': javaEnabled,
    'javascript_enabled': javascriptEnabled,
    'cookie_enabled': cookieEnabled,
    'plugins': plugins,
    'do_not_track': doNotTrack,
  };
}

/// `browser_info.mobile`.
class UqpayMobileDetails extends UqpayJsonModel {
  /// Creates mobile details. [osType] must be **uppercase** (`IOS`,
  /// `ANDROID`); the confirm endpoint rejects lowercase with a 400.
  const UqpayMobileDetails({
    required this.deviceModel,
    required this.osType,
    required this.osVersion,
    this.carrier,
  });

  /// Decodes a `mobile` object. Throws [FormatException] on missing required
  /// fields.
  factory UqpayMobileDetails.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayMobileDetails(
      deviceModel: r.requireString('device_model'),
      osType: r.requireString('os_type'),
      osVersion: r.requireString('os_version'),
      carrier: r.optionalString('carrier'),
    );
  }

  /// Device model, e.g. `iPhone`.
  final String deviceModel;

  /// Uppercase OS type, e.g. `IOS`, `ANDROID`.
  final String osType;

  /// OS version string, e.g. `iOS 17.2`.
  final String osVersion;

  /// Carrier name; omitted when unknown (never a placeholder).
  final String? carrier;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'device_model': deviceModel,
    'os_type': osType,
    'os_version': osVersion,
    'carrier': carrier,
  });
}

/// `browser_info.location`. Only ever sent with a real
/// fix; the API rejects `"0"`/`"0"`. Latitude and longitude are **strings**.
class UqpayLocation extends UqpayJsonModel {
  /// Creates a location.
  const UqpayLocation({required this.lat, required this.lon, this.accuracy});

  /// Decodes a `location` object. Throws [FormatException] on missing
  /// coordinates.
  factory UqpayLocation.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayLocation(
      lat: r.requireString('lat'),
      lon: r.requireString('lon'),
      accuracy: r.optionalInt('accuracy'),
    );
  }

  /// Latitude as a decimal string.
  final String lat;

  /// Longitude as a decimal string.
  final String lon;

  /// Accuracy in metres.
  final int? accuracy;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'lat': lat,
    'lon': lon,
    'accuracy': accuracy,
  });
}

/// The device fingerprint feeding 3-D Secure risk (`browser_info`).
///
/// Design rule inherited from the wire contract: **never fabricate device
/// data** — leave an optional field unset rather than invent a value. The
/// snapshot must be frozen with the attempt and reused verbatim on retries so
/// the replayed body stays byte-identical.
class UqpayBrowserInfo extends UqpayJsonModel {
  /// Creates browser info. [timezone] is the UTC offset in **whole hours** as
  /// a string (`"8"`, `"-2"`); [language] a plain BCP-47 tag (`en-US`) — see
  /// [normalizeLanguageTag].
  const UqpayBrowserInfo({
    required this.browser,
    required this.deviceId,
    required this.language,
    required this.mobile,
    required this.screenHeight,
    required this.screenWidth,
    required this.timezone,
    this.acceptHeader = '*/*',
    this.screenColorDepth = 24,
    this.touchSupport = true,
    this.location,
    this.fonts,
    this.webglVendor,
    this.webglRenderer,
    this.hardwareConcurrency,
    this.deviceMemory,
  });

  /// Decodes a `browser_info` object. Throws [FormatException] on missing
  /// required fields.
  factory UqpayBrowserInfo.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final location = r.optionalObject('location');
    return UqpayBrowserInfo(
      acceptHeader: r.optionalString('accept_header') ?? '*/*',
      browser: UqpayBrowserDetails.fromJson(r.optionalObject('browser') ?? {}),
      deviceId: r.requireString('device_id'),
      language: r.requireString('language'),
      location: location == null ? null : UqpayLocation.fromJson(location),
      mobile: UqpayMobileDetails.fromJson(r.optionalObject('mobile') ?? {}),
      screenColorDepth: r.optionalInt('screen_color_depth') ?? 24,
      screenHeight: r.optionalInt('screen_height') ?? 0,
      screenWidth: r.optionalInt('screen_width') ?? 0,
      timezone: r.requireString('timezone'),
      touchSupport: r.optionalBool('touch_support') ?? true,
      fonts: r.optionalStringList('fonts'),
      webglVendor: r.optionalString('webgl_vendor'),
      webglRenderer: r.optionalString('webgl_renderer'),
      hardwareConcurrency: r.optionalInt('hardware_concurrency'),
      deviceMemory: r.optionalInt('device_memory'),
    );
  }

  /// Reduces a platform locale identifier to the plain BCP-47 tag the API
  /// accepts: `_` becomes `-` and any `@…` / `.…` extension is dropped, so
  /// `en_US@rg=myzzzz` → `en-US`. The API rejects the raw form with
  /// `"language is invalid"`.
  static String normalizeLanguageTag(String locale) {
    var tag = locale;
    for (final separator in const ['@', '.']) {
      final cut = tag.indexOf(separator);
      if (cut >= 0) {
        tag = tag.substring(0, cut);
      }
    }
    return tag.replaceAll('_', '-');
  }

  /// HTTP `Accept` header of the paying agent. The SDK sends `*/*`.
  final String acceptHeader;

  /// Browser capabilities.
  final UqpayBrowserDetails browser;

  /// A stable per-install device id.
  final String deviceId;

  /// BCP-47 language tag, e.g. `en-US`.
  final String language;

  /// Device location, only when a real fix is available.
  final UqpayLocation? location;

  /// Mobile device details.
  final UqpayMobileDetails mobile;

  /// Screen colour depth in bits (a JSON number).
  final int screenColorDepth;

  /// Screen height in points (a JSON number).
  final int screenHeight;

  /// Screen width in points (a JSON number).
  final int screenWidth;

  /// UTC offset in whole hours as a string (`"8"`, `"-2"`). Half-hour zones
  /// truncate toward zero — a documented limitation of the wire shape.
  final String timezone;

  /// Whether the device has a touch screen.
  final bool touchSupport;

  /// Installed fonts, when known.
  final List<String>? fonts;

  /// WebGL vendor, when known.
  final String? webglVendor;

  /// WebGL renderer, when known.
  final String? webglRenderer;

  /// Logical processor count, when known.
  final int? hardwareConcurrency;

  /// Physical memory in whole GB, when known.
  final int? deviceMemory;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'accept_header': acceptHeader,
    'browser': browser.toJson(),
    'device_id': deviceId,
    'language': language,
    'location': location?.toJson(),
    'mobile': mobile.toJson(),
    'screen_color_depth': screenColorDepth,
    'screen_height': screenHeight,
    'screen_width': screenWidth,
    'timezone': timezone,
    'touch_support': touchSupport,
    'fonts': fonts,
    'webgl_vendor': webglVendor,
    'webgl_renderer': webglRenderer,
    'hardware_concurrency': hardwareConcurrency,
    'device_memory': deviceMemory,
  });
}

/// The body of `POST /api/v2/payment_intents/{id}/confirm`.
///
/// [ipAddress] is required by the API for 3-D Secure card confirms but is
/// **omitted** — never fabricated — when the device address is unknown.
class UqpayConfirmRequest extends UqpayJsonModel {
  /// Creates a confirm body.
  const UqpayConfirmRequest({
    required this.paymentMethod,
    required this.browserInfo,
    this.ipAddress,
  });

  /// Decodes a confirm body. Throws [FormatException] on missing required
  /// objects.
  factory UqpayConfirmRequest.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return UqpayConfirmRequest(
      paymentMethod: UqpayConfirmPaymentMethod.fromJson(
        r.optionalObject('payment_method') ?? {},
      ),
      browserInfo: UqpayBrowserInfo.fromJson(
        r.optionalObject('browser_info') ?? {},
      ),
      ipAddress: r.optionalString('ip_address', emptyAsNull: true),
    );
  }

  /// The method and its details.
  final UqpayConfirmPaymentMethod paymentMethod;

  /// The frozen device snapshot.
  final UqpayBrowserInfo browserInfo;

  /// The customer device's real interface address, or `null` to omit.
  final String? ipAddress;

  @override
  Map<String, Object?> toJson() => jsonWithoutNulls(<String, Object?>{
    'payment_method': paymentMethod.toJson(),
    'browser_info': browserInfo.toJson(),
    'ip_address': ipAddress,
  });

  @override
  String toString() =>
      'UqpayConfirmRequest(paymentMethod: ${paymentMethod.type})';
}
