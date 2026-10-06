/// Builds the risk-data snapshot (`browser_info`) the confirm body carries.
/// Internal — never exported.
library;

import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

/// Builds a best-effort [UqpayBrowserInfo] from what Flutter itself can see:
/// screen metrics, locale, platform and timezone. A pure-Dart SDK has no
/// native identifiers, so the device id is a random per-session value and
/// the OS version is not probed (the gateway treats the snapshot as
/// best-effort risk data, not authentication).
///
/// The snapshot is built **once per sheet session** and reused for every
/// confirm built in that session, so a retried confirm body is byte-identical
/// and reuses its idempotency pin.
UqpayBrowserInfo buildDeviceSnapshot({
  required MediaQueryData mediaQuery,
  required Locale locale,
  required DateTime nowUtc,
  required TargetPlatform platform,
  required bool isWeb,
  Random? random,
}) {
  final osType = isWeb
      ? 'WEB'
      : switch (platform) {
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
    browser: UqpayBrowserDetails(
      userAgent: 'uqpay_sdk_flutter ($osType)',
    ),
    deviceId: deviceId,
    language: locale.toLanguageTag(),
    mobile: UqpayMobileDetails(
      deviceModel: osType,
      osType: osType,
      osVersion: 'unknown',
    ),
    // The gateway accepts 1–9999 only (0×0 is rejected as
    // `invalid_payment_method`). MediaQuery can briefly be 0×0 at startup.
    screenHeight: mediaQuery.size.height.round().clamp(1, 9999),
    screenWidth: mediaQuery.size.width.round().clamp(1, 9999),
    // The offset of the device's local zone from UTC, in whole hours, read
    // through the injected clock (never DateTime.now).
    timezone: nowUtc.toLocal().timeZoneOffset.inHours.toString(),
  );
}
