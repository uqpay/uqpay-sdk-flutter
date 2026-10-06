/// Builds the `browser_info` block a headless confirm has to carry.
///
/// The drop-in sheet does this for you. A merchant driving
/// `UqpayPayments.confirm` themselves has to supply it, so the sample app
/// shows exactly what "best-effort risk data from what Flutter can see"
/// means: screen metrics, locale, platform and UTC offset. No native
/// identifier is collected and none is invented.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// Builds a snapshot from [context].
///
/// Build it **once per checkout** and reuse it: a retried confirm must send
/// byte-identical bytes so the SDK can reuse its idempotency pin.
UqpayBrowserInfo buildBrowserInfo(BuildContext context, {Random? random}) {
  final media = MediaQuery.of(context);
  final locale = Localizations.maybeLocaleOf(context) ?? const Locale('en');
  final osType = kIsWeb
      ? 'WEB'
      : switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'IOS',
          TargetPlatform.android => 'ANDROID',
          _ => 'OTHER',
        };
  final rng = random ?? Random.secure();
  final deviceId = List<String>.generate(
    32,
    (_) => rng.nextInt(16).toRadixString(16),
  ).join();
  return UqpayBrowserInfo(
    browser: const UqpayBrowserDetails(userAgent: 'uqpay_sdk_flutter_example'),
    deviceId: deviceId,
    language: locale.toLanguageTag(),
    mobile: UqpayMobileDetails(
      deviceModel: osType,
      osType: osType,
      osVersion: 'unknown',
    ),
    screenHeight: media.size.height.round(),
    screenWidth: media.size.width.round(),
    timezone: DateTime.now().timeZoneOffset.inHours.toString(),
  );
}
