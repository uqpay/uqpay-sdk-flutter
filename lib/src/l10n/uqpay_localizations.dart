import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Every user-facing string the UQPAY drop-in sheet (and the SDK's other
/// widgets) can show, in one overridable place.
///
/// The base class **is** the English catalogue: each getter returns the
/// shipped English string. To localise or reword, subclass it and override
/// what you need, then either pass the instance to
/// `UqpayPaymentSheet.present(localizations: …)` for one sheet, or install a
/// `LocalizationsDelegate` that returns your instances app-wide alongside
/// [delegate]:
///
/// ```dart
/// class GermanUqpayStrings extends UqpayLocalizations {
///   const GermanUqpayStrings();
///   @override
///   String get paySheetTitle => 'Zahlung';
/// }
/// ```
///
/// Widget code inside the SDK never hardcodes a user-facing string literal —
/// a test greps for `Text('…')` in the sheet sources — and currency amounts
/// are formatted through `intl` (`UqpayAmount.format`), never concatenated by
/// hand.
class UqpayLocalizations {
  /// Creates the English string catalogue. Subclasses override getters.
  const UqpayLocalizations();

  /// Resolves the ambient catalogue: the one installed with [delegate] (or a
  /// merchant's own delegate) when present, else the built-in English one.
  ///
  /// Never returns null and never throws, so SDK widgets can be used without
  /// any localisation setup.
  static UqpayLocalizations of(BuildContext context) =>
      Localizations.of<UqpayLocalizations>(context, UqpayLocalizations) ??
      const UqpayLocalizations();

  /// A delegate that serves the built-in English catalogue for every locale.
  ///
  /// Add it to a `MaterialApp.localizationsDelegates` list to make
  /// [UqpayLocalizations.of] resolve through the normal localisation
  /// machinery; merchants shipping their own translations register their own
  /// delegate ahead of this one instead.
  static const LocalizationsDelegate<UqpayLocalizations> delegate =
      _UqpayLocalizationsDelegate();

  // ---- Shared chrome ------------------------------------------------------

  /// Title at the top of the payment sheet.
  String get paySheetTitle => 'Payment';

  /// Label of the affordance that closes the sheet.
  String get close => 'Close';

  /// Label of an explicit cancel control.
  String get cancel => 'Cancel';

  /// Label of a retry affordance after a failure.
  String get retry => 'Try again';

  /// Label of the affordance that closes a finished sheet.
  String get done => 'Done';

  /// Semantic label for the sheet's modal barrier.
  String get dismissBarrierLabel => 'Dismiss';

  /// Semantic label of the drag handle that closes the sheet.
  String get dragHandleLabel => 'Close the payment sheet';

  // ---- Async states -------------------------------------------------------

  /// Shown while the payment intent is being loaded.
  String get loadingPayment => 'Loading payment details…';

  /// Headline when the intent could not be loaded.
  String get loadFailedTitle => 'Something went wrong';

  /// Headline when the intent offers no payment method the sheet can render.
  String get noMethodsTitle => 'No payment methods are available';

  /// Body when the intent offers no renderable payment method.
  String get noMethodsBody =>
      'This payment cannot be completed right now. '
      'Please contact the merchant or try another way to pay.';

  // ---- Sandbox banner -----------------------------------------------------

  /// The banner drawn at the top of the sheet in the sandbox environment.
  String get testModeBanner => 'TEST MODE — no real money will move';

  /// Screen-reader label for the sandbox banner.
  String get testModeBannerSemantics =>
      'Test mode. This is a sandbox payment; no real money will move.';

  // ---- Web card limitation ------------------------------------------------

  /// Notice above the method list on web when card entry was hidden.
  String get webCardUnavailableNotice =>
      'Card entry is not available in the browser yet. '
      'Choose another way to pay.';

  /// Body when card was the only method and the sheet runs in a browser.
  String get webCardOnlyBody =>
      'This payment accepts cards only, and card entry is not available in '
      'the browser yet. Please pay from the mobile app instead.';

  // ---- Method list --------------------------------------------------------

  /// Headline above the payment-method list.
  String get chooseMethodTitle => 'Choose how to pay';

  /// The display name of a wire payment-method [type] such as `card` or
  /// `paynow`. Unknown types fall back to the raw string.
  String methodDisplayName(String type) => switch (type) {
    'card' => 'Card',
    'wechatpay' => 'WeChat Pay',
    'alipaycn' => 'Alipay',
    'alipayhk' => 'AlipayHK',
    'grabpay' => 'GrabPay',
    'paynow' => 'PayNow',
    'unionpay' => 'UnionPay',
    'truemoney' => 'TrueMoney',
    'tng' => "Touch 'n Go",
    'gcash' => 'GCash',
    'dana' => 'DANA',
    'kakaopay' => 'Kakao Pay',
    'tosspay' => 'Toss Pay',
    'naverpay' => 'Naver Pay',
    _ => type,
  };

  // ---- Card form ----------------------------------------------------------

  /// Headline above the card form.
  String get cardDetailsTitle => 'Card details';

  /// Label of the card-number field.
  String get cardNumberLabel => 'Card number';

  /// Label of the expiry-date field.
  String get expiryLabel => 'Expiry date';

  /// Placeholder of the expiry-date field.
  String get expiryHint => 'MM/YY';

  /// Label of the CVC/CVV field.
  String get securityCodeLabel => 'Security code';

  /// Label of the cardholder-name field.
  String get cardholderNameLabel => 'Name on card';

  /// Label of the billing-email field. The gateway requires `billing.email`
  /// on a card confirm, so the field is mandatory rather than optional.
  String get billingEmailLabel => 'Email';

  /// Heading above the billing-address fields.
  String get billingAddressTitle => 'Billing address';

  /// Label of the billing street field.
  String get billingStreetLabel => 'Address';

  /// Label of the billing city field.
  String get billingCityLabel => 'City';

  /// Label of the billing state/province field.
  String get billingStateLabel => 'State or province';

  /// Label of the billing postcode field.
  String get billingPostcodeLabel => 'Postal code';

  /// Label of the billing country picker.
  String get billingCountryLabel => 'Country or region';

  /// Label of the pay button; [amount] is already currency-formatted.
  String payAmount(String amount) => 'Pay $amount';

  /// Validation message for an invalid card number.
  String get errorInvalidCardNumber => 'Enter a valid card number';

  /// Validation message for a malformed expiry date.
  String get errorInvalidExpiry => 'Enter a valid expiry date';

  /// Validation message for an expiry date in the past.
  String get errorCardExpired => 'This card has expired';

  /// Validation message for an invalid CVC/CVV.
  String get errorInvalidSecurityCode => 'Enter a valid security code';

  /// Validation message for a missing cardholder name.
  String get errorNameRequired => 'Enter the name on the card';

  /// Validation message for a cardholder name longer than the gateway
  /// accepts (128 characters).
  String get errorNameTooLong => 'The name on the card is too long';

  /// Validation message for a missing or malformed billing email.
  String get errorInvalidEmail => 'Enter a valid email address';

  /// Validation message for a missing billing street.
  String get errorStreetRequired => 'Enter your billing address';

  /// Validation message for a missing billing city.
  String get errorCityRequired => 'Enter your city';

  /// Validation message for a missing billing state/province.
  String get errorStateRequired => 'Enter your state or province';

  /// Validation message for a missing billing postcode.
  String get errorPostcodeRequired => 'Enter your postal code';

  /// Validation message for a missing billing country selection.
  String get errorCountryRequired => 'Select your country or region';

  // ---- Confirm in flight --------------------------------------------------

  /// Headline while the confirm request is in flight.
  String get processingTitle => 'Processing your payment';

  /// Body while the confirm request is in flight — also the explanation of
  /// why the sheet cannot be closed right now.
  String get processingBody =>
      'Please keep this screen open while your payment is confirmed.';

  /// Announced when the customer tries to close the sheet mid-confirm.
  String get cannotCloseWhileProcessing =>
      'Your payment is still being processed. '
      'This screen will update when it finishes.';

  /// Headline while a verification step (3-D Secure) is in progress.
  String get verifyingTitle => 'Waiting for verification';

  /// Body while a verification step is in progress.
  String get verifyingBody =>
      'Complete the verification step to finish paying.';

  /// Headline while the outcome of a confirmed payment is awaited.
  String get awaitingOutcomeTitle => 'Waiting for confirmation';

  /// Body while the outcome of a confirmed payment is awaited.
  String get awaitingOutcomeBody =>
      'This can take a moment. This screen updates automatically.';

  // ---- QR -----------------------------------------------------------------

  /// Instruction above the QR code; [method] is a display name from
  /// [methodDisplayName].
  String qrInstruction(String method) => 'Scan this code with $method to pay';

  /// Instruction above the QR code when the wallet is unknown (a re-served
  /// QR whose intent names no method, or a method this catalogue has no
  /// display name for).
  String get qrInstructionAnyApp =>
      'Scan this code with your payment app to pay';

  /// Countdown line under the QR code; [time] is a formatted `m:ss` string,
  /// or `h:mm:ss` when an hour or more remains.
  String qrExpiresIn(String time) => 'Expires in $time';

  /// Headline when the QR code expired before the payment was confirmed.
  String get qrExpiredTitle => 'This code has expired';

  /// Body when the QR code expired before the payment was confirmed.
  String get qrExpiredBody =>
      'The payment was not confirmed before the code timed out. If you '
      'already scanned it, check with the merchant before paying again.';

  /// Accessibility label for the rendered QR image.
  String get qrCodeSemanticLabel => 'Payment QR code';

  /// Shown when a server-hosted QR image failed to load.
  String get qrImageLoadFailed => 'The code could not be displayed.';

  // ---- Bank transfer ------------------------------------------------------

  /// Headline above the bank-transfer details.
  String get bankDetailsTitle => 'Transfer details';

  /// Instruction above the bank-transfer details.
  String get bankDetailsBody =>
      'Transfer to this account to complete your payment.';

  /// Label of the receiving bank's name.
  String get bankNameLabel => 'Bank';

  /// Label of the receiving account number.
  String get accountNumberLabel => 'Account number';

  /// Label of the receiving routing number.
  String get routingNumberLabel => 'Routing number';

  // ---- Results ------------------------------------------------------------

  /// Headline of the success state.
  String get successTitle => 'Payment successful';

  /// Body of the success state.
  String get successBody => 'You can close this screen.';

  /// Headline of the pending (outcome unknown) state.
  String get pendingTitle => 'Payment in progress';

  /// Body of the pending state.
  String get pendingBody =>
      'Your payment has not been confirmed yet. You can close this screen — '
      'your order is completed once the payment goes through.';

  /// Headline of the failure state.
  String get failedTitle => 'Payment failed';

  /// Headline of the cancelled state (the intent was cancelled).
  String get canceledTitle => 'Payment cancelled';

  /// Body of the cancelled state.
  String get canceledBody => 'This payment was cancelled. Nothing was paid.';

  // ---- 3-D Secure ----------------------------------------------------------

  /// Default title of the `UqpayChallengePage` app bar.
  String get verificationTitle => 'Verification';
}

/// Serves the built-in English [UqpayLocalizations] for every locale.
class _UqpayLocalizationsDelegate
    extends LocalizationsDelegate<UqpayLocalizations> {
  const _UqpayLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<UqpayLocalizations> load(Locale locale) =>
      SynchronousFuture<UqpayLocalizations>(const UqpayLocalizations());

  @override
  bool shouldReload(_UqpayLocalizationsDelegate old) => false;
}
