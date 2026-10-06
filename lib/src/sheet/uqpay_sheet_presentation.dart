import 'package:flutter/foundation.dart';

/// How `UqpayPaymentSheet` opens: the full method list, the card form
/// directly, or a single wallet confirmed immediately.
///
/// Mirrors the Android SDK's `Presentation` and the React Native
/// `presentation` option, so a merchant moving between SDKs keeps the same
/// three choices with the same semantics.
///
/// This hierarchy is sealed and **frozen for 1.x**; new modes would be a
/// major version.
@immutable
sealed class UqpaySheetPresentation {
  const UqpaySheetPresentation();

  /// The default: the customer chooses from every method the intent
  /// offers (filtered by `allowedPaymentMethods` when set).
  const factory UqpaySheetPresentation.methodList() =
      UqpayMethodListPresentation;

  /// Skips the list and opens the card form directly. There is no list to
  /// return to, so closing the sheet cancels the payment (`Canceled` before
  /// a confirm has left the device, `Pending` after). If the intent does
  /// not offer `card` — or the sheet runs in a browser, where card entry is
  /// not available — the sheet shows its "no payment methods" screen.
  const factory UqpaySheetPresentation.cardOnly() = UqpayCardOnlyPresentation;

  /// Confirms [method] (a wallet type such as `grabpay` or `alipaycn`) as
  /// soon as the intent is loaded and shows that wallet's QR code or
  /// instructions. The customer never sees a list. `card` is not a wallet:
  /// passing it throws [ArgumentError] — use `cardOnly()` instead. If the
  /// intent does not offer [method], the sheet shows its "no payment
  /// methods" screen.
  const factory UqpaySheetPresentation.singleWallet(String method) =
      UqpaySingleWalletPresentation;
}

/// See [UqpaySheetPresentation.methodList].
final class UqpayMethodListPresentation extends UqpaySheetPresentation {
  /// Creates the method-list presentation.
  const UqpayMethodListPresentation();

  @override
  bool operator ==(Object other) => other is UqpayMethodListPresentation;

  @override
  int get hashCode => (UqpayMethodListPresentation).hashCode;

  @override
  String toString() => 'UqpaySheetPresentation.methodList()';
}

/// See [UqpaySheetPresentation.cardOnly].
final class UqpayCardOnlyPresentation extends UqpaySheetPresentation {
  /// Creates the card-only presentation.
  const UqpayCardOnlyPresentation();

  @override
  bool operator ==(Object other) => other is UqpayCardOnlyPresentation;

  @override
  int get hashCode => (UqpayCardOnlyPresentation).hashCode;

  @override
  String toString() => 'UqpaySheetPresentation.cardOnly()';
}

/// See [UqpaySheetPresentation.singleWallet].
final class UqpaySingleWalletPresentation extends UqpaySheetPresentation {
  /// Creates a single-wallet presentation for [method].
  ///
  /// Throws [ArgumentError] when [method] is blank or is `card`.
  const UqpaySingleWalletPresentation(this.method)
    : assert(method != '', 'method must not be empty');

  /// The wallet method type to confirm, e.g. `grabpay`.
  final String method;

  /// Validates [method] eagerly (the const constructor cannot throw). Called
  /// by the sheet before any network request.
  void validate() {
    final trimmed = method.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(method, 'presentation', 'method is empty');
    }
    if (trimmed == 'card') {
      throw ArgumentError.value(
        method,
        'presentation',
        'singleWallet("card") is not a wallet — use '
            'UqpaySheetPresentation.cardOnly() for card',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is UqpaySingleWalletPresentation && other.method == method;

  @override
  int get hashCode => Object.hash(UqpaySingleWalletPresentation, method);

  @override
  String toString() => 'UqpaySheetPresentation.singleWallet($method)';
}
