/// The sample app's single piece of state: configuration, the SDK handle,
/// the merchant backend and the last payment result.
library;

import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import 'package:uqpay_sdk_flutter_example/src/backend/merchant_backend.dart';
import 'package:uqpay_sdk_flutter_example/src/config/app_config.dart';

/// How the merchant backend is doing.
enum BackendStatus {
  /// Not asked yet.
  unknown,

  /// A request is in flight.
  checking,

  /// `GET /health` answered.
  ready,

  /// The last call failed; see [DemoController.backendError].
  failed,
}

/// A currency offered by the sample checkout.
///
/// The list deliberately spans a zero-decimal (JPY) and a three-decimal (BHD)
/// currency next to the usual two-decimal ones, because the amount is a
/// decimal string in **major** units end to end and nothing anywhere scales
/// it. Switching currency here changes only the sample amount
/// and how `UqpayAmount.format` renders it.
class DemoCurrency {
  /// Creates a currency entry.
  const DemoCurrency({
    required this.code,
    required this.label,
    required this.note,
    required this.sampleAmount,
  });

  /// ISO 4217 code sent on the wire.
  final String code;

  /// Human name.
  final String label;

  /// What makes this currency interesting for amount handling.
  final String note;

  /// A well-formed amount for this currency, in major units.
  final String sampleAmount;
}

/// The currencies the sample checkout offers.
const List<DemoCurrency> demoCurrencies = <DemoCurrency>[
  DemoCurrency(
    code: 'USD',
    label: 'US dollar',
    note: '2 decimals',
    sampleAmount: '8.98',
  ),
  DemoCurrency(
    code: 'SGD',
    label: 'Singapore dollar',
    note: '2 decimals',
    sampleAmount: '12.50',
  ),
  DemoCurrency(
    code: 'JPY',
    label: 'Japanese yen',
    note: '0 decimals — "898" is 898 yen, not 8.98',
    sampleAmount: '898',
  ),
  DemoCurrency(
    code: 'BHD',
    label: 'Bahraini dinar',
    note: '3 decimals — "8.980" keeps all three',
    sampleAmount: '8.980',
  ),
  DemoCurrency(
    code: 'HKD',
    label: 'Hong Kong dollar',
    note: '2 decimals',
    sampleAmount: '68.00',
  ),
  DemoCurrency(
    code: 'CNY',
    label: 'Chinese yuan',
    note: '2 decimals',
    sampleAmount: '58.00',
  ),
];

/// Everything the screens read and drive.
class DemoController extends ChangeNotifier {
  /// Creates the controller. Tests inject [backend], [isWeb] and [currentUri].
  DemoController({
    required this.config,
    MerchantBackend? backend,
    bool? isWeb,
    Uri? currentUri,
  }) : backend = backend ?? MerchantBackend(baseUrl: config.backendBaseUrl),
       isWeb = isWeb ?? kIsWeb,
       _currentUri = currentUri;

  /// The mobile app scheme the intent's `return_url` uses.
  ///
  /// The in-app webview recognises a navigation to this scheme as the end of
  /// the browser step and never hands it to the OS, so nothing has to be
  /// registered in the Android manifest or the iOS Info.plist for the sample
  /// to work.
  static const String mobileReturnUrl = 'uqpayexample://payment-return';

  /// Build-time configuration.
  final AppConfig config;

  /// The merchant backend client.
  final MerchantBackend backend;

  /// Whether this build runs in a browser.
  final bool isWeb;

  final Uri? _currentUri;

  UqpayEnvironment _environment = UqpayEnvironment.sandbox;
  UqpaySdk? _sdk;
  String? _sdkError;
  BackendStatus _backendStatus = BackendStatus.unknown;
  MerchantBackendException? _backendError;
  String? _backendEnvironment;
  List<UqpayPaymentResult> _unresolved = const <UqpayPaymentResult>[];
  UqpayPaymentResult? _result;
  UqpayPaymentIntent? _intent;
  String _amount = demoCurrencies.first.sampleAmount;
  String _currency = demoCurrencies.first.code;
  String _description = 'Sample order';
  String? _busy;
  String? _notice;

  /// The environment the runtime switch is on. Starts on sandbox **always**,
  /// even when the build asked for production: flipping to production has to
  /// be a deliberate on-screen action.
  UqpayEnvironment get environment => _environment;

  /// The configured SDK handle, or `null` when [UqpaySdk.init] refused.
  UqpaySdk? get sdk => _sdk;

  /// Why [UqpaySdk.init] refused, when it did (desktop, bad override).
  String? get sdkError => _sdkError;

  /// The payment API, or `null` before a successful init.
  UqpayPayments? get payments => _sdk?.payments;

  /// Backend reachability.
  BackendStatus get backendStatus => _backendStatus;

  /// The last backend failure, for the on-screen error.
  MerchantBackendException? get backendError => _backendError;

  /// The environment the backend reported from `GET /health`.
  String? get backendEnvironment => _backendEnvironment;

  /// Interrupted payments found at startup.
  List<UqpayPaymentResult> get unresolved => _unresolved;

  /// The most recent payment result from either surface.
  UqpayPaymentResult? get result => _result;

  /// The intent the checkout is working on.
  UqpayPaymentIntent? get intent => _intent;

  /// Amount as a decimal string in major units. Never scaled.
  String get amount => _amount;

  /// ISO 4217 currency code.
  String get currency => _currency;

  /// Free-text order description sent to the backend.
  String get description => _description;

  /// A label for the current long-running operation, or `null`.
  String? get busy => _busy;

  /// A one-off message for the tester (a resolved redirect return, …).
  String? get notice => _notice;

  /// The currency entry for [currency].
  DemoCurrency get currencyEntry => demoCurrencies.firstWhere(
    (c) => c.code == _currency,
    orElse: () => demoCurrencies.first,
  );

  /// [amount] parsed, or `null` when it is not a valid decimal string.
  UqpayAmount? get parsedAmount => UqpayAmount.tryParse(_amount);

  /// [amount] rendered for display, or `null` when it does not parse.
  ///
  /// This is the only place the app formats money, and it goes through the
  /// SDK's `UqpayAmount` — the same code path for every currency and every
  /// intent status.
  String? get formattedAmount => parsedAmount?.format(currencyCode: _currency);

  /// The `return_url` registered on the intent at creation.
  ///
  /// On web this is the app's own page, so a full-page 3-D Secure redirect
  /// comes back here and `UqpayReturnHandler.consume(Uri.base)` at startup
  /// resolves it. On Android and iOS it is an app scheme the in-app webview
  /// recognises.
  Uri get returnUrl => isWeb
      ? (_currentUri ?? Uri.base).replace(
          query: '',
          fragment: '',
        )
      : Uri.parse(mobileReturnUrl);

  /// The URL a merchant would register when their backend can template the
  /// `return_url` per intent.
  ///
  /// The reference backend cannot: UQPAY fixes `return_url` at intent
  /// creation and assigns the intent id in the same call, so there is no
  /// moment at which both are known. The SDK covers that gap by persisting
  /// the in-flight intent id before it redirects, which is why
  /// `UqpayReturnHandler.consume` still works here. Shown on screen so the
  /// shape of the parameterised URL is visible.
  Uri? get parameterisedReturnUrl {
    final id = _intent?.id;
    return id == null ? null : UqpayReturnHandler.returnUrlFor(returnUrl, id);
  }

  /// Initialises the SDK, checks the backend, then resolves anything left
  /// over from a previous run.
  Future<void> bootstrap() async {
    _initSdk();
    await checkBackend();
    await _consumeWebReturn();
    await _reconcileUnresolved();
  }

  /// Calls `GET /health` and `POST /client-token`, and re-initialises the SDK
  /// if the backend disclosed a `client_id`.
  Future<void> checkBackend() async {
    _backendStatus = BackendStatus.checking;
    _backendError = null;
    notifyListeners();
    try {
      _backendEnvironment = await backend.health();
      // Fetching one token up front proves the whole credential chain works
      // before the tester types an amount, and lets the SDK be configured
      // with the client id when the backend hands one over.
      await backend.authToken();
      _backendStatus = BackendStatus.ready;
      if (backend.clientId != null && _sdk?.clientId != backend.clientId) {
        _initSdk();
      }
    } on MerchantBackendException catch (error) {
      _backendStatus = BackendStatus.failed;
      _backendError = error;
    }
    notifyListeners();
  }

  /// Switches environment and rebuilds the SDK handle.
  void setEnvironment(UqpayEnvironment value) {
    if (value == _environment) {
      return;
    }
    _environment = value;
    _result = null;
    _intent = null;
    _initSdk();
    notifyListeners();
  }

  /// Sets the amount (a decimal string in major units — never scaled).
  void setAmount(String value) {
    _amount = value;
    notifyListeners();
  }

  /// Sets the currency and resets the amount to that currency's sample.
  void setCurrency(String code) {
    if (code == _currency) {
      return;
    }
    _currency = code;
    _amount = demoCurrencies
        .firstWhere(
          (c) => c.code == code,
          orElse: () => demoCurrencies.first,
        )
        .sampleAmount;
    notifyListeners();
  }

  /// Sets the order description.
  void setDescription(String value) {
    _description = value;
    notifyListeners();
  }

  /// Records a result from either surface.
  void setResult(UqpayPaymentResult value) {
    _result = value;
    if (value.intent != null) {
      _intent = value.intent;
    }
    notifyListeners();
  }

  /// Clears the one-off notice.
  void clearNotice() {
    _notice = null;
    notifyListeners();
  }

  /// Asks the backend to create a payment intent for the current order.
  ///
  /// Returns `null` and sets [backendError] when the backend refuses; never
  /// throws.
  Future<UqpayPaymentIntent?> createIntent() async {
    final parsed = parsedAmount;
    if (parsed == null) {
      _backendError = const MerchantBackendException(
        summary: 'That amount is not a decimal string',
        detail:
            'Amounts travel as major units, for example "8.98" or "898". '
            'No currency symbols, no thousands separators, no minor units.',
      );
      notifyListeners();
      return null;
    }
    _busy = 'Creating the payment intent…';
    _backendError = null;
    notifyListeners();
    try {
      final created = await backend.createIntent(
        amount: _amount,
        currency: _currency,
        returnUrl: returnUrl,
        description: _description,
      );
      _intent = created;
      _result = null;
      return created;
    } on MerchantBackendException catch (error) {
      _backendError = error;
      _backendStatus = error.isUnreachable
          ? BackendStatus.failed
          : _backendStatus;
      return null;
    } finally {
      _busy = null;
      notifyListeners();
    }
  }

  /// Re-reads an intent from the server and records the mapped result.
  /// Never throws.
  Future<void> reconcile(String intentId) async {
    final api = payments;
    if (api == null) {
      return;
    }
    _busy = 'Reconciling $intentId…';
    notifyListeners();
    try {
      setResult(await api.reconcile(intentId));
    } finally {
      _busy = null;
      notifyListeners();
    }
  }

  /// Drops an entry from the startup "unresolved" list once it is dealt with.
  void dismissUnresolved(UqpayPaymentResult entry) {
    _unresolved = <UqpayPaymentResult>[
      for (final item in _unresolved)
        if (!identical(item, entry)) item,
    ];
    notifyListeners();
  }

  @override
  void dispose() {
    backend.close();
    _sdk?.payments.close();
    super.dispose();
  }

  void _initSdk() {
    try {
      _sdk = UqpaySdk.init(
        environment: _environment,
        tokenProvider: backend.authToken,
        clientId: backend.clientId,
        onBehalfOf: config.onBehalfOf,
      );
      _sdkError = null;
      // UqpaySdk.init throws for configuration mistakes on purpose.
      // A sample app a human runs on an unsupported platform should say so
      // on screen rather than die on the first frame.
      // ignore: avoid_catching_errors
    } on UnsupportedError catch (error) {
      _sdk = null;
      _sdkError = error.message ?? 'This platform is not supported.';
      // ignore: avoid_catching_errors — same reason as above.
    } on ArgumentError catch (error) {
      _sdk = null;
      _sdkError = error.message.toString();
    }
  }

  /// Web only: a 3-D Secure redirect that came back to this page resolves
  /// here, against the server.
  Future<void> _consumeWebReturn() async {
    final api = payments;
    if (!isWeb || api == null) {
      return;
    }
    try {
      final resolved = await UqpayReturnHandler(
        payments: api,
      ).consume(_currentUri ?? Uri.base);
      if (resolved != null) {
        _notice =
            'Came back from a redirect challenge. The status below was '
            'read from the server, never from the URL.';
        setResult(resolved);
      }
    } on Object {
      // consume() is documented never to throw; a plugin-less test host can
      // still make the underlying storage fail. Never block startup on it.
    }
  }

  /// Startup reconcile of anything a previous run left pinned.
  Future<void> _reconcileUnresolved() async {
    final api = payments;
    if (api == null) {
      return;
    }
    try {
      _unresolved = await api.reconcileUnresolved();
    } on Object {
      // Storage is unavailable (no plugin registered in a test host). The
      // app is fully usable without the startup sweep.
      _unresolved = const <UqpayPaymentResult>[];
    }
    notifyListeners();
  }
}
