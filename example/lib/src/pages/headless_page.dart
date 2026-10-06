/// The same payment, driven by the app's own UI through the typed headless
/// API — no SDK widget anywhere on this screen.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import 'package:uqpay_sdk_flutter_example/src/state/browser_info.dart';
import 'package:uqpay_sdk_flutter_example/src/state/demo_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/state/theme_controller.dart';
import 'package:uqpay_sdk_flutter_example/src/widgets/common.dart';
import 'package:uqpay_sdk_flutter_example/src/widgets/result_view.dart';

/// Headless checkout: `retrieveIntent` → `createFlow` → `confirm`, with the
/// progress stream, cancel, pause and resume all on screen.
class HeadlessPage extends StatefulWidget {
  const HeadlessPage({
    required this.controller,
    required this.theme,
    super.key,
  });

  final DemoController controller;
  final ThemeController theme;

  @override
  State<HeadlessPage> createState() => _HeadlessPageState();
}

class _HeadlessPageState extends State<HeadlessPage> {
  final TextEditingController _cardName = TextEditingController();
  final TextEditingController _cardNumber = TextEditingController();
  final TextEditingController _expiryMonth = TextEditingController();
  final TextEditingController _expiryYear = TextEditingController();
  final TextEditingController _cvc = TextEditingController();

  // Billing details, prefilled with demo values. The gateway rejects a card
  // confirm whose billing email or address fields are missing or empty.
  final TextEditingController _billingEmail = TextEditingController(
    text: 'shopper@example.com',
  );
  final TextEditingController _billingStreet = TextEditingController(
    text: '1 Main Street',
  );
  final TextEditingController _billingCity = TextEditingController(
    text: 'Springfield',
  );
  final TextEditingController _billingState = TextEditingController(
    text: 'CA',
  );
  final TextEditingController _billingPostcode = TextEditingController(
    text: '90210',
  );
  final TextEditingController _billingCountry = TextEditingController(
    text: 'US',
  );

  UqpayPaymentIntent? _intent;
  UqpayBrowserInfo? _browserInfo;
  UqpayPaymentFlow? _flow;
  UqpayPaymentStatus? _status;
  StreamSubscription<UqpayPaymentStatus>? _subscription;
  UqpayPaymentResult? _result;
  String _method = 'card';
  String? _problem;
  bool _working = false;

  bool get _isWeb => widget.controller.isWeb;

  @override
  void initState() {
    super.initState();
    _intent = widget.controller.intent;
    if (_isWeb) {
      _method = _walletMethods.isEmpty ? '' : _walletMethods.first;
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _cardName.dispose();
    _cardNumber.dispose();
    _expiryMonth.dispose();
    _expiryYear.dispose();
    _cvc.dispose();
    _billingEmail.dispose();
    _billingStreet.dispose();
    _billingCity.dispose();
    _billingState.dispose();
    _billingPostcode.dispose();
    _billingCountry.dispose();
    super.dispose();
  }

  List<String> get _walletMethods => <String>[
    for (final type in _intent?.availablePaymentMethodTypes ?? const <String>[])
      if (type != 'card') type,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Headless checkout'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Theme: ${widget.theme.modeLabel}',
            onPressed: widget.theme.cycleMode,
            icon: Icon(widget.theme.modeIcon),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          if (_working) const LinearProgressIndicator(),
          _intentCard(),
          if (_intent != null) _methodCard(),
          if (_intent != null) _confirmCard(),
          if (_status != null) _progressCard(),
          if (_result != null)
            SectionCard(
              title: 'Result',
              icon: Icons.fact_check_outlined,
              children: <Widget>[
                ResultView(result: _result!, onReconcile: _reconcile),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _awaitOutcomeAgain,
                    icon: const Icon(Icons.hourglass_empty),
                    label: const Text('payments.awaitOutcome() again'),
                  ),
                ),
              ],
            ),
          if (_problem != null)
            SectionCard(
              title: 'Cannot continue',
              icon: Icons.error_outline,
              tone: Theme.of(context).colorScheme.errorContainer,
              children: <Widget>[
                SelectableText(
                  _problem!,
                  key: const Key('headless-problem'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ cards

  Widget _intentCard() {
    final intent = _intent;
    return SectionCard(
      title: 'Step 1 — the payment intent',
      icon: Icons.looks_one_outlined,
      subtitle:
          'Your backend creates it. The app never holds an API key, so it '
          'cannot create one itself.',
      children: <Widget>[
        if (intent == null)
          const Note('No intent yet. Create one to continue.')
        else ...<Widget>[
          LabelledValue(label: 'Id', value: intent.id, monospace: true),
          LabelledValue(label: 'Status', value: intent.status.raw),
          LabelledValue(
            label: 'Amount',
            value: intent.amount == null
                ? '—'
                : '"${intent.amount!.toWireString()}" '
                      '${intent.currency ?? ''}',
            monospace: true,
          ),
          LabelledValue(
            label: 'Methods',
            value:
                (intent.availablePaymentMethodTypes ?? const <String>[])
                    .join(', ')
                    .trim()
                    .isEmpty
                ? 'not listed by the server'
                : intent.availablePaymentMethodTypes!.join(', '),
          ),
          LabelledValue(
            label: 'return_url',
            value: intent.returnUrl ?? '—',
            monospace: true,
          ),
          if (intent.nextAction != null)
            LabelledValue(
              label: 'next_action',
              value: intent.nextAction?.type?.raw ?? '—',
            ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('create-intent-button'),
              onPressed: _working ? null : _createIntent,
              icon: const Icon(Icons.add),
              label: Text(intent == null ? 'Create intent' : 'New intent'),
            ),
            if (intent != null)
              OutlinedButton.icon(
                key: const Key('retrieve-intent-button'),
                onPressed: _working ? null : _retrieveIntent,
                icon: const Icon(Icons.download_outlined),
                label: const Text('payments.retrieveIntent()'),
              ),
            if (intent != null)
              OutlinedButton.icon(
                key: const Key('cancel-intent-button'),
                onPressed: _working ? null : _cancelIntent,
                icon: const Icon(Icons.block_outlined),
                label: const Text('payments.cancelIntent()'),
              ),
          ],
        ),
        if (intent != null)
          const Note(
            'cancelIntent() cancels the intent ON THE SERVER and is '
            "terminal. flow.cancel() further down only calls off this app's "
            'flow and sends nothing — two different things with two '
            'different results.',
            icon: Icons.info_outline,
          ),
      ],
    );
  }

  Widget _methodCard() {
    final wallets = _walletMethods;
    return SectionCard(
      title: 'Step 2 — the payment method',
      icon: Icons.looks_two_outlined,
      children: <Widget>[
        if (_isWeb)
          const Note(
            'Web build: no card form. Card fields rendered in the merchant '
            'origin would move a merchant from SAQ A to SAQ A-EP, so the web '
            'build offers wallet / QR / redirect methods only; card entry is '
            'not available in the browser in this version.',
            icon: Icons.security_outlined,
          ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            if (!_isWeb)
              ChoiceChip(
                key: const Key('method-card'),
                label: const Text('card'),
                selected: _method == 'card',
                onSelected: (_) => setState(() => _method = 'card'),
              ),
            for (final wallet in wallets)
              ChoiceChip(
                label: Text(wallet),
                selected: _method == wallet,
                onSelected: (_) => setState(() => _method = wallet),
              ),
          ],
        ),
        if (_isWeb && wallets.isEmpty)
          const Note(
            'The server listed no non-card method for this intent, so there '
            'is nothing to confirm from a browser. Enable a wallet method on '
            'the sandbox account, or run this flow on Android or iOS.',
            icon: Icons.info_outline,
          ),
        if (!_isWeb && _method == 'card') ...<Widget>[
          const SizedBox(height: 12),
          const Note(
            'Use a sandbox test card from your UQPAY dashboard. Nothing you '
            'type here is logged, persisted or copied anywhere by the SDK.',
            icon: Icons.info_outline,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('card-name-field'),
            controller: _cardName,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name on card',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('card-number-field'),
            controller: _cardNumber,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Card number',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('expiry-month-field'),
                  controller: _expiryMonth,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'MM',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('expiry-year-field'),
                  controller: _expiryYear,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'YYYY',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('cvc-field'),
                  controller: _cvc,
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'CVC',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Billing', style: Theme.of(context).textTheme.titleSmall),
          const Note(
            'The gateway requires billing email and a full address (street, '
            'city, postal code, ISO alpha-2 country code; state where the '
            'country uses one). Empty strings are rejected.',
            icon: Icons.info_outline,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('billing-email-field'),
            controller: _billingEmail,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('billing-street-field'),
            controller: _billingStreet,
            keyboardType: TextInputType.streetAddress,
            decoration: const InputDecoration(
              labelText: 'Address',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('billing-city-field'),
                  controller: _billingCity,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'City',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('billing-state-field'),
                  controller: _billingState,
                  decoration: const InputDecoration(
                    labelText: 'State or province',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('billing-postcode-field'),
                  controller: _billingPostcode,
                  decoration: const InputDecoration(
                    labelText: 'Postal code',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('billing-country-field'),
                  controller: _billingCountry,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  maxLength: 2,
                  decoration: const InputDecoration(
                    labelText: 'Country code',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _confirmCard() => SectionCard(
    title: 'Step 3 — confirm and wait',
    icon: Icons.looks_3_outlined,
    subtitle:
        'createFlow() gives you the progress stream, cancel, pause and '
        'resume. confirm() reads the intent first, sends one confirm with a '
        'persisted idempotency key, presents any 3-D Secure challenge, then '
        'polls until the SERVER decides.',
    children: <Widget>[
      FilledButton.icon(
        key: const Key('confirm-button'),
        onPressed: _working || _method.isEmpty ? null : _confirm,
        icon: const Icon(Icons.lock_outline),
        label: const Text('payments.createFlow(...).confirm()'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
      const Note(
        'Card flows get the 5-minute outcome budget; wallet and QR flows get '
        '10 minutes, which is what a QR code needs.',
      ),
    ],
  );

  Widget _progressCard() {
    final status = _status!;
    final flow = _flow;
    return SectionCard(
      title: 'Progress',
      icon: Icons.timeline,
      children: <Widget>[
        LabelledValue(label: 'Phase', value: status.phase.raw),
        LabelledValue(label: 'Polls', value: '${status.pollCount}'),
        LabelledValue(
          label: 'Intent status',
          value: status.intent?.status.raw ?? '—',
        ),
        LabelledValue(
          label: 'next_action',
          value: status.intent?.nextAction?.type?.raw ?? '—',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              key: const Key('cancel-flow-button'),
              onPressed: flow == null || flow.isDone
                  ? null
                  : () => flow.cancel(UqpayCancelReason.userTappedCancel),
              icon: const Icon(Icons.close),
              label: const Text('flow.cancel()'),
            ),
            OutlinedButton.icon(
              onPressed: flow == null || flow.isDone
                  ? null
                  : () => setState(
                      () => flow.isPaused ? flow.resume() : flow.pause(),
                    ),
              icon: Icon(
                flow != null && flow.isPaused ? Icons.play_arrow : Icons.pause,
              ),
              label: Text(
                flow != null && flow.isPaused
                    ? 'flow.resume()'
                    : 'flow.pause()',
              ),
            ),
          ],
        ),
        const Note(
          'Cancelling before the confirm has left the device resolves '
          'Canceled; cancelling after it has left resolves Pending, because '
          'the server may still take the payment.',
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- actions

  Future<void> _createIntent() async {
    setState(() {
      _problem = null;
      _working = true;
    });
    final created = await widget.controller.createIntent();
    if (!mounted) {
      return;
    }
    setState(() {
      _working = false;
      _intent = created;
      _result = null;
      _status = null;
      _flow = null;
      if (created == null) {
        _problem = widget.controller.backendError?.detail;
      } else if (_isWeb) {
        _method = _walletMethods.isEmpty ? '' : _walletMethods.first;
      }
    });
  }

  Future<void> _retrieveIntent() async {
    final api = widget.controller.payments;
    final intent = _intent;
    if (api == null || intent == null) {
      return;
    }
    setState(() => _working = true);
    final result = await api.retrieveIntent(intent.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _working = false;
      switch (result) {
        case UqpayIntentRetrieved(:final intent):
          _intent = intent;
          _problem = null;
        case UqpayIntentUnavailable(:final error):
          _problem =
              'retrieveIntent returned Unavailable: ${error.code.raw} — '
              '${error.userMessage}';
      }
    });
  }

  Future<void> _confirm() async {
    final api = widget.controller.payments;
    final intent = _intent;
    if (api == null || intent == null) {
      return;
    }
    final request = _buildRequest();
    if (request == null) {
      return;
    }
    await _subscription?.cancel();
    final flow = api.createFlow(
      intentId: intent.id,
      request: request,
      outcomeDeadline: _method == 'card'
          ? const Duration(minutes: 5)
          : const Duration(minutes: 10),
      challengePresenter: _presenter(),
    );
    setState(() {
      _flow = flow;
      _result = null;
      _problem = null;
      _working = true;
    });
    _subscription = flow.status.listen((status) {
      if (mounted) {
        setState(() => _status = status);
      }
    });
    final result = await flow.confirm();
    if (!mounted) {
      return;
    }
    widget.controller.setResult(result);
    setState(() {
      _working = false;
      _result = result;
      if (result.intent != null) {
        _intent = result.intent;
      }
    });
  }

  Future<void> _cancelIntent() async {
    final api = widget.controller.payments;
    final intent = _intent;
    if (api == null || intent == null) {
      return;
    }
    setState(() => _working = true);
    // The server may refuse (an intent that already succeeded, or a client
    // token that is not authorised to cancel). Either way this RETURNS a
    // result rather than throwing: a refusal arrives as
    // UqpayPaymentFailed carrying the server's error.
    final result = await api.cancelIntent(intent.id);
    if (!mounted) {
      return;
    }
    widget.controller.setResult(result);
    setState(() {
      _working = false;
      _result = result;
      if (result.intent != null) {
        _intent = result.intent;
      }
    });
  }

  Future<void> _awaitOutcomeAgain() async {
    final api = widget.controller.payments;
    final intent = _intent;
    if (api == null || intent == null) {
      return;
    }
    setState(() => _working = true);
    final result = await api.awaitOutcome(
      intent.id,
      deadline: const Duration(minutes: 2),
    );
    if (!mounted) {
      return;
    }
    widget.controller.setResult(result);
    setState(() {
      _working = false;
      _result = result;
    });
  }

  Future<void> _reconcile(String intentId) async {
    final api = widget.controller.payments;
    if (api == null) {
      return;
    }
    setState(() => _working = true);
    final result = await api.reconcile(intentId);
    if (!mounted) {
      return;
    }
    widget.controller.setResult(result);
    setState(() {
      _working = false;
      _result = result;
    });
  }

  UqpayChallengePresenter _presenter() {
    if (_isWeb) {
      // Full-page redirect. The page unloads, so this future never completes
      // on success; UqpayReturnHandler.consume(Uri.base) at startup resolves
      // the payment when the browser comes back.
      return UqpayRedirectChallengePresenter();
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    return UqpayWebviewChallengePresenter(navigator: () => navigator);
  }

  UqpayConfirmRequest? _buildRequest() {
    final info = _browserInfo ??= buildBrowserInfo(context);
    if (_method != 'card') {
      return UqpayConfirmRequest(
        paymentMethod: UqpayConfirmPaymentMethod.wallet(
          _method,
          const UqpayWalletDetails(osType: kIsWeb ? 'WEB' : null),
        ),
        browserInfo: info,
      );
    }
    final problem = _cardProblem();
    if (problem != null) {
      setState(() => _problem = problem);
      return null;
    }
    return UqpayConfirmRequest(
      paymentMethod: UqpayConfirmPaymentMethod.card(
        UqpayCardDetails(
          cardName: _cardName.text.trim(),
          cardNumber: _digitsOf(_cardNumber.text),
          expiryMonth: _expiryMonth.text.trim().padLeft(2, '0'),
          expiryYear: _expiryYear.text.trim(),
          cvc: _cvc.text.trim(),
          billing: _billingDetails(),
        ),
      ),
      browserInfo: info,
    );
  }

  /// Structural validation mirroring what `UqpayCardDetails` enforces, so the
  /// app never sends details the SDK would reject at construction time.
  ///
  /// A production checkout adds Luhn, brand and CVC-length rules on top —
  /// the drop-in sheet already has all of them, which is a good reason to use
  /// it rather than rebuild it.
  String? _cardProblem() {
    if (_cardName.text.trim().isEmpty) {
      return 'Enter the name on the card.';
    }
    if (!RegExp(r'^[0-9]{12,19}$').hasMatch(_digitsOf(_cardNumber.text))) {
      return 'The card number must be 12 to 19 digits.';
    }
    final month = _expiryMonth.text.trim().padLeft(2, '0');
    if (!RegExp(r'^(0[1-9]|1[0-2])$').hasMatch(month)) {
      return 'The expiry month must be 01 to 12.';
    }
    if (!RegExp(r'^[0-9]{4}$').hasMatch(_expiryYear.text.trim())) {
      return 'The expiry year must be four digits, for example 2029.';
    }
    if (!RegExp(r'^[0-9]{3,4}$').hasMatch(_cvc.text.trim())) {
      return 'The CVC must be 3 or 4 digits.';
    }
    if (!_billingEmail.text.trim().contains('@')) {
      return 'Enter the billing email address.';
    }
    if (_billingStreet.text.trim().isEmpty ||
        _billingCity.text.trim().isEmpty ||
        _billingPostcode.text.trim().isEmpty) {
      return 'Enter the billing street, city and postal code.';
    }
    if (!RegExp(r'^[A-Za-z]{2}$').hasMatch(_billingCountry.text.trim())) {
      return 'The country code must be two letters (ISO 3166-1 alpha-2).';
    }
    return null;
  }

  /// The billing block the gateway requires on a card confirm. `state` is
  /// omitted when left blank — not every country has one.
  UqpayBillingDetails _billingDetails() {
    final state = _billingState.text.trim();
    return UqpayBillingDetails(
      email: _billingEmail.text.trim(),
      address: UqpayAddress(
        countryCode: _billingCountry.text.trim().toUpperCase(),
        state: state.isEmpty ? null : state,
        city: _billingCity.text.trim(),
        street: _billingStreet.text.trim(),
        postcode: _billingPostcode.text.trim(),
      ),
    );
  }

  static String _digitsOf(String value) =>
      value.replaceAll(RegExp('[^0-9]'), '');
}
