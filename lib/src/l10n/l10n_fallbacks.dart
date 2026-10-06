/// Blank-proof accessors for the strings that label a control. Internal —
/// never exported.
///
/// A merchant override that returns an empty string for one of these would
/// leave a button with no visible label and nothing for a screen reader to
/// announce. Like the sandbox banner text, each falls back to the built-in
/// English string when the override is blank.
library;

import 'package:uqpay_sdk_flutter/src/l10n/uqpay_localizations.dart';

const UqpayLocalizations _defaults = UqpayLocalizations();

String _orDefault(String value, String fallback) =>
    value.trim().isEmpty ? fallback : value;

/// Non-blank labels for controls.
extension UqpayLocalizationsLabels on UqpayLocalizations {
  /// [UqpayLocalizations.close], never blank.
  String get closeLabel => _orDefault(close, _defaults.close);

  /// [UqpayLocalizations.done], never blank.
  String get doneLabel => _orDefault(done, _defaults.done);

  /// [UqpayLocalizations.payAmount], never blank.
  String payAmountLabel(String amount) =>
      _orDefault(payAmount(amount), _defaults.payAmount(amount));

  /// [UqpayLocalizations.paySheetTitle], never blank (the pay button's label
  /// before the amount is known).
  String get paySheetTitleLabel =>
      _orDefault(paySheetTitle, _defaults.paySheetTitle);

  /// [UqpayLocalizations.testModeBanner], never blank.
  String get testModeBannerLabel =>
      _orDefault(testModeBanner, _defaults.testModeBanner);

  /// [UqpayLocalizations.testModeBannerSemantics], never blank.
  String get testModeBannerSemanticsLabel =>
      _orDefault(testModeBannerSemantics, _defaults.testModeBannerSemantics);

  /// The instruction above a QR code for wire method [type]: names the
  /// wallet when the catalogue knows it, otherwise a method-agnostic
  /// sentence — never "Scan this code with  to pay" or a raw wire id.
  String qrInstructionFor(String type) {
    final trimmed = type.trim();
    final name = trimmed.isEmpty ? '' : methodDisplayName(trimmed).trim();
    if (name.isEmpty || name == trimmed) {
      return _orDefault(qrInstructionAnyApp, _defaults.qrInstructionAnyApp);
    }
    return qrInstruction(name);
  }
}
