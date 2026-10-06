/// The card entry form (mobile only — it is kept off web builds).
/// Internal — never exported.
///
/// Field hygiene: suggestions and autocorrect are off on
/// every field, the CVC is obscured, values are read once at pay time and
/// never logged, stored or copied to the clipboard by the SDK. Autofill is
/// read-only via `AutofillHints.creditCard*`; the SDK never saves an
/// autofill entry.
library;

import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/src/l10n/l10n_fallbacks.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/billing_countries.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_formatters.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_validation.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// What the form hands back when the customer taps pay. Values live only on
/// the call stack.
class SheetCardInput {
  /// Creates the value bundle.
  const SheetCardInput({
    required this.cardNumber,
    required this.expiryMonth,
    required this.expiryYear,
    required this.cvc,
    required this.cardholderName,
    required this.email,
    required this.street,
    required this.city,
    required this.state,
    required this.postcode,
    required this.countryCode,
    required this.network,
  });

  /// PAN, digits only.
  final String cardNumber;

  /// Two-digit month, e.g. `09`.
  final String expiryMonth;

  /// Four-digit year, e.g. `2030`.
  final String expiryYear;

  /// Security code.
  final String cvc;

  /// Name on the card.
  final String cardholderName;

  /// Billing email. Required by the gateway on a card confirm.
  final String email;

  /// Billing street. Required by the gateway.
  final String street;

  /// Billing city. Required by the gateway.
  final String city;

  /// Billing state or province, possibly empty. Required by the form only
  /// for [statesRequiredFor]; sent only when filled.
  final String state;

  /// Billing postcode. Required by the gateway.
  final String postcode;

  /// Billing country, ISO 3166-1 alpha-2. Required by the gateway.
  final String countryCode;

  /// Detected brand wire name, or `null` when undetected — never the string
  /// `unknown`.
  final String? network;
}

/// Billing countries (ISO 3166-1 alpha-2) for which the form requires a
/// state or province. Elsewhere (SG, HK, …) the field is optional — the
/// gateway accepted SG without one and rejected US in the sandbox —
/// and an empty value is not sent.
const Set<String> statesRequiredFor = <String>{
  'US',
  'CA',
  'AU',
  'IN',
  'BR',
  'MX',
};

/// The card form.
class SheetCardFormView extends StatefulWidget {
  /// Creates the form. [now] supplies "today" for expiry validation from
  /// the injected clock. [onSubmit] receives the validated
  /// values; [onBack] returns to the method list (or `null` to hide the
  /// affordance).
  const SheetCardFormView({
    required this.l10n,
    required this.payLabel,
    required this.now,
    required this.onSubmit,
    required this.onBack,
    this.prefillName,
    this.prefillEmail,
    this.prefillAddress,
    super.key,
  });

  /// String catalogue.
  final UqpayLocalizations l10n;

  /// The pay-button label, amount already formatted (the amount
  /// string comes from the sheet's single formatting path).
  final String payLabel;

  /// Supplies the current UTC instant, from the injected clock.
  final DateTime Function() now;

  /// Called with validated values when the customer taps pay.
  final ValueChanged<SheetCardInput> onSubmit;

  /// Returns to the method list.
  final VoidCallback? onBack;

  /// Cardholder name to start the form with, from merchant-supplied billing
  /// details. The customer can edit it; what is sent is what the form holds
  /// at pay time.
  final String? prefillName;

  /// Billing email to start the form with, from merchant-supplied billing
  /// details. Editable, like [prefillName].
  final String? prefillEmail;

  /// Billing address to start the address fields with, from
  /// merchant-supplied billing details. Every part is editable.
  final UqpayAddress? prefillAddress;

  @override
  State<SheetCardFormView> createState() => _SheetCardFormViewState();
}

class _SheetCardFormViewState extends State<SheetCardFormView> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _number = TextEditingController();
  final TextEditingController _expiry = TextEditingController();
  final TextEditingController _cvc = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _street = TextEditingController();
  final TextEditingController _city = TextEditingController();
  final TextEditingController _state = TextEditingController();
  final TextEditingController _postcode = TextEditingController();
  final FocusNode _numberFocus = FocusNode(debugLabel: 'uqpay-card-number');
  final FocusNode _expiryFocus = FocusNode(debugLabel: 'uqpay-card-expiry');
  final FocusNode _cvcFocus = FocusNode(debugLabel: 'uqpay-card-cvc');
  final FocusNode _nameFocus = FocusNode(debugLabel: 'uqpay-card-name');
  final FocusNode _emailFocus = FocusNode(debugLabel: 'uqpay-card-email');
  final FocusNode _streetFocus = FocusNode(debugLabel: 'uqpay-card-street');
  final FocusNode _cityFocus = FocusNode(debugLabel: 'uqpay-card-city');
  final FocusNode _stateFocus = FocusNode(debugLabel: 'uqpay-card-state');
  final FocusNode _postcodeFocus = FocusNode(
    debugLabel: 'uqpay-card-postcode',
  );

  UqpayCardBrand? _brand;
  UqpayBillingCountry? _country;

  /// Whether the customer has tried to pay. Until then an incomplete field
  /// (still being typed, or left empty) is not shown as an error.
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _number.addListener(_onNumberChanged);
    _emailFocus.addListener(_onEmailFocusChanged);
    _name.text = widget.prefillName ?? '';
    _email.text = widget.prefillEmail ?? '';
    final address = widget.prefillAddress;
    _street.text = address?.street ?? '';
    _city.text = address?.city ?? '';
    _state.text = address?.state ?? '';
    _postcode.text = address?.postcode ?? '';
    // The merchant's country when they supplied a real one, otherwise the
    // device's own region as an opening guess the customer can change. An
    // unrecognised code selects nothing rather than silently substituting a
    // country — the mistake the iOS SDK's nine-entry table shipped.
    _country =
        UqpayBillingCountries.lookup(address?.countryCode) ??
        UqpayBillingCountries.lookup(
          WidgetsBinding.instance.platformDispatcher.locale.countryCode,
        );
  }

  @override
  void dispose() {
    _number.dispose();
    _expiry.dispose();
    _cvc.dispose();
    _name.dispose();
    _email.dispose();
    _street.dispose();
    _city.dispose();
    _state.dispose();
    _postcode.dispose();
    _numberFocus.dispose();
    _expiryFocus.dispose();
    _cvcFocus.dispose();
    _nameFocus.dispose();
    _emailFocus.dispose();
    _streetFocus.dispose();
    _cityFocus.dispose();
    _stateFocus.dispose();
    _postcodeFocus.dispose();
    super.dispose();
  }

  /// Leaving the email field re-runs its validator: a half-typed address is
  /// not flagged while the customer is still in the field, but is once
  /// they move on.
  void _onEmailFocusChanged() {
    if (!_emailFocus.hasFocus && mounted) {
      setState(() {});
    }
  }

  void _onNumberChanged() {
    final brand = UqpayCardValidator.detectBrand(digitsOf(_number.text));
    if (brand != _brand) {
      setState(() => _brand = brand);
    }
  }

  /// Maps a card-field validity to its message. `incomplete` is only an
  /// error once the customer has tried to pay.
  String? _message(
    UqpayCardFieldValidity validity, {
    required String invalid,
    String? expired,
  }) => switch (validity) {
    UqpayCardFieldValidity.valid => null,
    UqpayCardFieldValidity.incomplete => _submitted ? invalid : null,
    UqpayCardFieldValidity.expired => expired ?? invalid,
    UqpayCardFieldValidity.invalid => invalid,
  };

  /// A required free-text field: empty is "incomplete".
  String? _required(String? value, String message) =>
      _submitted && (value ?? '').trim().isEmpty ? message : null;

  String? _validateNumber(String? value) => _message(
    UqpayCardValidator.validateNumber(digitsOf(value ?? '')),
    invalid: widget.l10n.errorInvalidCardNumber,
  );

  String? _validateExpiry(String? value) => _message(
    UqpayCardValidator.validateExpiry(digitsOf(value ?? ''), widget.now()),
    invalid: widget.l10n.errorInvalidExpiry,
    expired: widget.l10n.errorCardExpired,
  );

  String? _validateCvc(String? value) => _message(
    UqpayCardValidator.validateCvc(digitsOf(value ?? ''), _brand),
    invalid: widget.l10n.errorInvalidSecurityCode,
  );

  String? _validateName(String? value) {
    // The gateway (and UqpayCardDetails) reject a name over 128 characters.
    if ((value ?? '').trim().length > UqpayCardDetails.maxCardNameLength) {
      return widget.l10n.errorNameTooLong;
    }
    return _required(value, widget.l10n.errorNameRequired);
  }

  String? _validateEmail(String? value) {
    final validity = UqpayCardValidator.validateEmail(value ?? '');
    // An address reads as "invalid" until its domain is typed, so before the
    // first submit it is only judged once the customer leaves the field.
    if (!_submitted &&
        _emailFocus.hasFocus &&
        validity == UqpayCardFieldValidity.invalid) {
      return null;
    }
    return _message(validity, invalid: widget.l10n.errorInvalidEmail);
  }

  String? _validateStreet(String? value) =>
      _required(value, widget.l10n.errorStreetRequired);

  String? _validateCity(String? value) =>
      _required(value, widget.l10n.errorCityRequired);

  String? _validateState(String? value) =>
      statesRequiredFor.contains(_country?.code)
      ? _required(value, widget.l10n.errorStateRequired)
      : null;

  String? _validatePostcode(String? value) =>
      _required(value, widget.l10n.errorPostcodeRequired);

  String? _validateCountry(UqpayBillingCountry? value) =>
      _submitted && value == null ? widget.l10n.errorCountryRequired : null;

  void _submit() {
    setState(() => _submitted = true);
    // Form.validate() announces the first failing field's message to screen
    // readers itself — exactly once per failed submit.
    final formValid = _formKey.currentState?.validate() ?? false;
    if (!formValid || _country == null) {
      return;
    }
    final digits = digitsOf(_number.text);
    final expiry = digitsOf(_expiry.text);
    widget.onSubmit(
      SheetCardInput(
        cardNumber: digits,
        expiryMonth: expiry.substring(0, 2),
        expiryYear: '20${expiry.substring(2, 4)}',
        cvc: digitsOf(_cvc.text),
        cardholderName: _name.text.trim(),
        email: _email.text.trim(),
        street: _street.text.trim(),
        city: _city.text.trim(),
        state: _state.text.trim(),
        postcode: _postcode.text.trim(),
        countryCode: _country!.code,
        network: _brand?.wireName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final theme = Theme.of(context);
    // Validation runs per field, never form-wide: typing in one field
    // must not light up every other one, and FormState only announces on an
    // explicit validate(), so typing never triggers announcements.
    // After a failed submit every field re-validates on each rebuild, so an
    // error clears as soon as it is fixed — and the state field follows a
    // country change.
    final fieldValidation = _submitted
        ? AutovalidateMode.always
        : AutovalidateMode.onUserInteraction;
    return Form(
      key: _formKey,
      child: AutofillGroup(
        // Never offer to save the card to the platform's autofill store.
        onDisposeAction: AutofillContextAction.cancel,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (widget.onBack != null)
                    IconButton(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                      tooltip: l10n.closeLabel,
                      constraints: const BoxConstraints(
                        minWidth: kSheetFormTapTarget,
                        minHeight: kSheetFormTapTarget,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      l10n.cardDetailsTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (_brand != null)
                    // Brand names are proper nouns, shown untranslated.
                    Text(
                      _brand!.displayName,
                      style: theme.textTheme.labelMedium,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                enableIMEPersonalizedLearning: false,
                key: const ValueKey<String>('uqpay-card-number'),
                // Reads left-to-right in RTL locales too.
                textDirection: TextDirection.ltr,
                controller: _number,
                focusNode: _numberFocus,
                validator: _validateNumber,
                autovalidateMode: fieldValidation,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.creditCardNumber],
                enableSuggestions: false,
                autocorrect: false,
                inputFormatters: [UqpayCardNumberFormatter()],
                decoration: InputDecoration(labelText: l10n.cardNumberLabel),
                onFieldSubmitted: (_) => _expiryFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey<String>('uqpay-card-expiry'),
                      // Reads left-to-right in RTL locales too.
                      textDirection: TextDirection.ltr,
                      controller: _expiry,
                      focusNode: _expiryFocus,
                      validator: _validateExpiry,
                      autovalidateMode: fieldValidation,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [
                        AutofillHints.creditCardExpirationDate,
                      ],
                      enableSuggestions: false,
                      autocorrect: false,
                      inputFormatters: [UqpayExpiryDateFormatter()],
                      decoration: InputDecoration(
                        labelText: l10n.expiryLabel,
                        hintText: l10n.expiryHint,
                      ),
                      onFieldSubmitted: (_) => _cvcFocus.requestFocus(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey<String>('uqpay-card-cvc'),
                      // Reads left-to-right in RTL locales too.
                      textDirection: TextDirection.ltr,
                      controller: _cvc,
                      focusNode: _cvcFocus,
                      validator: _validateCvc,
                      autovalidateMode: fieldValidation,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [
                        AutofillHints.creditCardSecurityCode,
                      ],
                      enableSuggestions: false,
                      autocorrect: false,
                      obscureText: true,
                      inputFormatters: [
                        UqpayCvcFormatter(maxLength: _brand?.cvcLength ?? 4),
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.securityCodeLabel,
                      ),
                      onFieldSubmitted: (_) => _nameFocus.requestFocus(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                enableIMEPersonalizedLearning: false,
                key: const ValueKey<String>('uqpay-card-name'),
                controller: _name,
                focusNode: _nameFocus,
                validator: _validateName,
                autovalidateMode: fieldValidation,
                keyboardType: TextInputType.name,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.creditCardName],
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.cardholderNameLabel,
                ),
                onFieldSubmitted: (_) => _emailFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                enableIMEPersonalizedLearning: false,
                key: const ValueKey<String>('uqpay-card-email'),
                // Reads left-to-right in RTL locales too.
                textDirection: TextDirection.ltr,
                controller: _email,
                focusNode: _emailFocus,
                validator: _validateEmail,
                autovalidateMode: fieldValidation,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                // An email address is not card data, so autofill is a plain
                // convenience here — but suggestions stay off for consistency
                // with every other field on this form.
                autofillHints: const [AutofillHints.email],
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(labelText: l10n.billingEmailLabel),
                onFieldSubmitted: (_) => _streetFocus.requestFocus(),
              ),
              const SizedBox(height: 20),
              // The gateway requires country_code, city, street and postcode
              // on every card confirm and rejects the payment outright
              // without them (observed against the sandbox). `state` is
              // required only for [statesRequiredFor] and sent only when
              // filled.
              Text(
                l10n.billingAddressTitle,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextFormField(
                enableIMEPersonalizedLearning: false,
                key: const ValueKey<String>('uqpay-card-street'),
                controller: _street,
                focusNode: _streetFocus,
                validator: _validateStreet,
                autovalidateMode: fieldValidation,
                keyboardType: TextInputType.streetAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.streetAddressLine1],
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(labelText: l10n.billingStreetLabel),
                onFieldSubmitted: (_) => _cityFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey<String>('uqpay-card-city'),
                      controller: _city,
                      focusNode: _cityFocus,
                      validator: _validateCity,
                      autovalidateMode: fieldValidation,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.addressCity],
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.billingCityLabel,
                      ),
                      onFieldSubmitted: (_) => _stateFocus.requestFocus(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey<String>('uqpay-card-state'),
                      controller: _state,
                      focusNode: _stateFocus,
                      validator: _validateState,
                      autovalidateMode: fieldValidation,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.addressState],
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.billingStateLabel,
                      ),
                      onFieldSubmitted: (_) => _postcodeFocus.requestFocus(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      enableIMEPersonalizedLearning: false,
                      key: const ValueKey<String>('uqpay-card-postcode'),
                      // Reads left-to-right in RTL locales too.
                      textDirection: TextDirection.ltr,
                      controller: _postcode,
                      focusNode: _postcodeFocus,
                      validator: _validatePostcode,
                      autovalidateMode: fieldValidation,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.characters,
                      autofillHints: const [AutofillHints.postalCode],
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.billingPostcodeLabel,
                      ),
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<UqpayBillingCountry>(
                key: const ValueKey<String>('uqpay-card-country'),
                initialValue: _country,
                isExpanded: true,
                validator: _validateCountry,
                autovalidateMode: fieldValidation,
                decoration: InputDecoration(
                  labelText: l10n.billingCountryLabel,
                ),
                items: [
                  for (final country in UqpayBillingCountries.all)
                    DropdownMenuItem<UqpayBillingCountry>(
                      value: country,
                      child: Text(
                        country.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _country = value),
              ),
              const SizedBox(height: 20),
              Semantics(
                button: true,
                child: FilledButton(
                  key: const ValueKey<String>('uqpay-pay-button'),
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(kSheetFormTapTarget + 4),
                  ),
                  child: Text(widget.payLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Minimum tap-target side for accessibility (duplicated from status_views to
/// keep this file self-contained for the import-boundary rules).
const double kSheetFormTapTarget = 48;
