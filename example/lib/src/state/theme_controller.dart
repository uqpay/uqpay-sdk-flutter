/// Host theming for the sample app, and the optional brand override handed
/// to the SDK's sheet.
library;

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// The host app's theme choice plus the "custom brand" toggle.
///
/// The two are deliberately independent. [mode] drives `MaterialApp.themeMode`
/// only: the sheet inherits it, which is how you can see that the SDK never
/// forces its own brightness. [brandOverride] supplies an
/// [UqpayAppearance] that restyles the sheet while the host app stays on its
/// own palette — so the effect of the override is unmistakable.
class ThemeController extends ChangeNotifier {
  /// The host app's seed colour.
  static const Color hostSeed = Color(0xFF1B4DFF);

  /// The seed used by the "custom brand" appearance.
  static const Color brandSeed = Color(0xFFEA5B0C);

  ThemeMode _mode = ThemeMode.system;
  bool _brandOverride = false;

  /// Which theme the host app is showing.
  ThemeMode get mode => _mode;

  /// Whether an [UqpayAppearance] override is handed to the sheet.
  bool get brandOverride => _brandOverride;

  /// The host light theme.
  ThemeData get light => _themeFor(Brightness.light, hostSeed);

  /// The host dark theme.
  ThemeData get dark => _themeFor(Brightness.dark, hostSeed);

  /// Cycles system → light → dark → system.
  void cycleMode() {
    _mode = switch (_mode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    notifyListeners();
  }

  /// Turns the brand override on or off.
  void toggleBrandOverride() {
    _brandOverride = !_brandOverride;
    notifyListeners();
  }

  /// A one-word label for [mode].
  String get modeLabel => switch (_mode) {
    ThemeMode.system => 'system',
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
  };

  /// The icon for the current [mode].
  IconData get modeIcon => switch (_mode) {
    ThemeMode.system => Icons.brightness_auto_outlined,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };

  /// The appearance to pass to the sheet, or `null` when the sheet should
  /// derive everything from the host theme.
  ///
  /// The override's colour scheme is built at the **host's** brightness on
  /// purpose: `UqpayAppearance` replaces colours, it does not flip
  /// brightness, and a merchant handing it a mismatched scheme would get an
  /// unreadable sheet.
  UqpayAppearance? appearanceFor(BuildContext context) {
    if (!_brandOverride) {
      return null;
    }
    final brightness = Theme.of(context).brightness;
    return UqpayAppearance(
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandSeed,
        brightness: brightness,
      ),
      cornerRadius: 4,
      payButtonStyle: FilledButton.styleFrom(
        backgroundColor: brandSeed,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
    );
  }

  static ThemeData _themeFor(Brightness brightness, Color seed) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ),
    useMaterial3: true,
  );
}
