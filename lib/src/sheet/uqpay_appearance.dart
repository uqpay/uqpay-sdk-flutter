import 'package:flutter/material.dart';

/// Optional theming for the drop-in payment sheet.
///
/// With no appearance supplied the sheet derives everything from the host
/// app's `Theme` — including brightness, which the sheet **never forces**:
/// light and dark mode both follow the host's `ThemeMode`. Every
/// field here is an override layered on top of that derived theme, so a
/// merchant can restyle one thing without re-specifying the rest:
///
/// ```dart
/// UqpayPaymentSheet.present(
///   context,
///   // …
///   appearance: const UqpayAppearance(cornerRadius: 4),
/// );
/// ```
@immutable
class UqpayAppearance {
  /// Creates an appearance override. Unset fields keep the host theme's
  /// values.
  const UqpayAppearance({
    this.colorScheme,
    this.cornerRadius,
    this.textTheme,
    this.payButtonStyle,
  });

  /// Replaces the sheet's colour scheme. Supply a scheme whose brightness
  /// matches the host theme's — the sheet does not flip brightness for you.
  final ColorScheme? colorScheme;

  /// Corner radius of the sheet surface, fields and buttons, in logical
  /// pixels.
  final double? cornerRadius;

  /// Overrides the sheet's text theme. Merged over the host's: styles (and
  /// style properties) left unset keep the host theme's values.
  final TextTheme? textTheme;

  /// Style of the primary pay button. Merged over the derived button style
  /// (including the [cornerRadius] shape): properties left unset keep it.
  final ButtonStyle? payButtonStyle;

  /// The theme the sheet renders with: [host] (the merchant app's theme,
  /// brightness untouched) with this appearance's overrides applied.
  ThemeData themeFor(ThemeData host) {
    var theme = host;
    final scheme = colorScheme;
    if (scheme != null) {
      theme = theme.copyWith(colorScheme: scheme);
    }
    final text = textTheme;
    if (text != null) {
      // Merged, not replaced: a partial override (just a weight) must not
      // drop the host's sizes and colours.
      theme = theme.copyWith(textTheme: theme.textTheme.merge(text));
    }
    final radius = cornerRadius;
    if (radius != null) {
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      );
      theme = theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: (theme.filledButtonTheme.style ?? const ButtonStyle())
              .copyWith(shape: WidgetStatePropertyAll<OutlinedBorder>(shape)),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: (theme.outlinedButtonTheme.style ?? const ButtonStyle())
              .copyWith(shape: WidgetStatePropertyAll<OutlinedBorder>(shape)),
        ),
        cardTheme: theme.cardTheme.copyWith(shape: shape),
      );
    }
    final buttonStyle = payButtonStyle;
    if (buttonStyle != null) {
      theme = theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: buttonStyle.merge(theme.filledButtonTheme.style),
        ),
      );
    }
    return theme;
  }

  @override
  bool operator ==(Object other) =>
      other is UqpayAppearance &&
      other.colorScheme == colorScheme &&
      other.cornerRadius == cornerRadius &&
      other.textTheme == textTheme &&
      other.payButtonStyle == payButtonStyle;

  @override
  int get hashCode =>
      Object.hash(colorScheme, cornerRadius, textTheme, payButtonStyle);
}
