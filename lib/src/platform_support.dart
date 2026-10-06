import 'package:flutter/foundation.dart';

/// Whether the SDK supports the platform the code is currently running on.
///
/// Deliberately implemented with [kIsWeb] and [defaultTargetPlatform] rather
/// than `dart:io`'s `Platform`, because importing `dart:io` would break both
/// the JS and the WebAssembly web builds.
bool get isSupportedPlatform => unsupportedPlatformName() == null;

/// The human-readable name of the current platform when it is **not**
/// supported, or `null` when the platform is supported.
///
/// Returning the name rather than a bool lets the caller put the actual
/// platform into the error message.
String? unsupportedPlatformName() {
  // Every browser is a supported target; `defaultTargetPlatform` on web
  // reports the underlying OS, which would otherwise read as desktop.
  if (kIsWeb) {
    return null;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => null,
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}
