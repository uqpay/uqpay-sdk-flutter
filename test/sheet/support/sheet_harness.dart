/// Shared helpers for the drop-in sheet's widget tests.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../../support/fakes.dart';

/// A [UqpayPayments] that remembers every flow it hands out, so the leak
/// test can assert that each one finished — a finished flow has closed its
/// status stream, so no subscription of the sheet's can still be live.
class TrackingPayments extends UqpayPayments {
  /// Creates the tracking API over the given fakes.
  TrackingPayments({
    required super.sdk,
    required super.httpClient,
    required super.clock,
    required super.storage,
    super.pollingPolicy,
    super.deviceIpResolver,
  }) : super.withDependencies();

  /// Every flow created through this API, in order.
  final List<UqpayPaymentFlow> flows = <UqpayPaymentFlow>[];

  @override
  UqpayPaymentFlow createFlow({
    required String intentId,
    UqpayConfirmRequest? request,
    Duration outcomeDeadline = UqpayPayments.defaultOutcomeDeadline,
    UqpayChallengePresenter? challengePresenter,
  }) {
    final flow = super.createFlow(
      intentId: intentId,
      request: request,
      outcomeDeadline: outcomeDeadline,
      challengePresenter: challengePresenter,
    );
    flows.add(flow);
    return flow;
  }
}

/// Everything a sheet widget test needs: scripted HTTP, a [ManualClock]
/// driving both the flow and the sheet's countdowns, flow tracking and
/// result capture.
class SheetHarness {
  /// Creates a harness with a fresh clock, transport and pin store.
  SheetHarness() : clock = ManualClock() {
    payments = TrackingPayments(
      sdk: sdkWithTokens(const <String>['tok']),
      httpClient: http,
      clock: clock,
      storage: storage,
      // No jitter: poll schedules are exact, so tests drive them precisely.
      pollingPolicy: PollingPolicy(jitter: 0),
      // Real interface enumeration never completes inside testWidgets' fake
      // async zone, and a hung resolver would hang every confirm.
      deviceIpResolver: () async => '198.51.100.7',
    );
  }

  /// The clock the sheet, the flow and the QR countdown all run on.
  final ManualClock clock;

  /// The scripted transport.
  final FakeHttpClient http = FakeHttpClient();

  /// The idempotency pin store.
  final InMemoryKeyValueStore storage = InMemoryKeyValueStore();

  /// The headless API the sheet under test consumes.
  late final TrackingPayments payments;

  /// Results delivered through `onResult` / `present`, in order (the
  /// exactly-once counting harness).
  final List<UqpayPaymentResult> results = <UqpayPaymentResult>[];

  /// Every flow the sheet started.
  List<UqpayPaymentFlow> get flows => payments.flows;

  /// Confirm POSTs sent so far.
  List<UqpayHttpRequest> get confirms =>
      http.requests.where((r) => r.url.path.endsWith('/confirm')).toList();

  /// Intent GETs sent so far.
  List<UqpayHttpRequest> get reads =>
      http.requests.where((r) => r.method == 'GET').toList();
}

/// The boundary the golden matrix captures: everything the sheet paints.
const Key sheetBoundaryKey = ValueKey<String>('uqpay-sheet-boundary');

/// The intent id used by [intentJson].
const String kIntentId = 'pi_123';

/// The default merchant return URL used in tests.
final Uri kReturnUrl = Uri.parse('myapp://payment-return');

/// A challenge presenter that records requests and returns a scripted
/// outcome.
class RecordingPresenter implements UqpayChallengePresenter {
  RecordingPresenter([this.outcome = const UqpayChallengeOutcome.timedOut()]);

  final UqpayChallengeOutcome outcome;
  final List<UqpayChallengeRequest> requests = <UqpayChallengeRequest>[];

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    requests.add(request);
    return outcome;
  }
}

/// Pumps until every pending microtask/future has settled, **without**
/// waiting for animations to stop.
///
/// The sheet's waiting screens hold a `CircularProgressIndicator`, which
/// animates forever, so `pumpAndSettle` times out on any screen the flow is
/// still working on. Timed work runs on the harness's [ManualClock], which
/// only moves when a test says so, so a fixed number of frames is enough to
/// drain everything that is actually ready.
Future<void> pumpUntilIdle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps the embeddable [UqpayPaymentSheet] inside a [MaterialApp].
Future<void> pumpEmbeddedSheet(
  WidgetTester tester,
  SheetHarness harness, {
  bool isWeb = false,
  ThemeData? theme,
  TextDirection textDirection = TextDirection.ltr,
  double textScale = 1.0,
  UqpayChallengePresenter? challengePresenter,
  UqpayLocalizations? localizations,
  UqpayBillingDetails? billingDetails,
  Set<String>? allowedPaymentMethods,
  UqpaySheetPresentation presentation =
      const UqpaySheetPresentation.methodList(),
  String intentId = kIntentId,
  UqpayPayments? payments,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ThemeData(colorSchemeSeed: Colors.indigo),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Directionality(textDirection: textDirection, child: child!),
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: sheetBoundaryKey,
          child: SingleChildScrollView(
            child: UqpayPaymentSheet(
              payments: payments ?? harness.payments,
              intentId: intentId,
              returnUrl: kReturnUrl,
              clock: harness.clock,
              isWebPlatform: isWeb,
              challengePresenter: challengePresenter,
              localizations: localizations,
              billingDetails: billingDetails,
              allowedPaymentMethods: allowedPaymentMethods,
              presentation: presentation,
              onResult: harness.results.add,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pumps a host app with a button that calls [UqpayPaymentSheet.present]
/// on tap and records the returned future.
Future<Future<UqpayPaymentResult>> presentSheet(
  WidgetTester tester,
  SheetHarness harness, {
  bool isWeb = false,
  ThemeData? theme,
  UqpayChallengePresenter? challengePresenter,
  UqpayLocalizations? localizations,
  String intentId = kIntentId,
}) async {
  final completer = Completer<Future<UqpayPaymentResult>>();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ThemeData(colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              key: const ValueKey<String>('open-sheet'),
              onPressed: () {
                final future = UqpayPaymentSheet.present(
                  context,
                  payments: harness.payments,
                  intentId: intentId,
                  returnUrl: kReturnUrl,
                  clock: harness.clock,
                  isWebPlatform: isWeb,
                  challengePresenter: challengePresenter,
                  localizations: localizations,
                );
                unawaited(future.then(harness.results.add));
                if (!completer.isCompleted) {
                  completer.complete(future);
                }
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open-sheet')));
  // Long enough for the modal route's entry transition; `pumpAndSettle`
  // would hang on any screen holding a progress indicator.
  await pumpUntilIdle(tester, frames: 40);
  return completer.future;
}

/// Scrolls the pay button into view and taps it.
///
/// The card form collects everything the gateway requires — card, name,
/// email and a full billing address — so on a test-sized viewport the button
/// starts below the fold, where a plain `tap` silently misses.
Future<void> tapPay(WidgetTester tester) async {
  final button = find.byKey(const ValueKey<String>('uqpay-pay-button'));
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
}

/// Fills the card form with a valid Visa card and returns.
Future<void> fillValidCard(
  WidgetTester tester, {
  String number = testPan,
  String expiry = '12/30',
  String cvc = testCvc,
  String name = 'Ada Lovelace',
  String email = 'ada@example.com',
  String street = '221B Baker Street',
  String city = 'London',
  String state = 'Greater London',
  String postcode = 'NW1 6XE',
}) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-number')),
    number,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-expiry')),
    expiry,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-cvc')),
    cvc,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-name')),
    name,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-email')),
    email,
  );
  // The gateway requires country_code, city, street and postcode on every
  // card confirm, so a "valid card" is not payable without them.
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-street')),
    street,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-city')),
    city,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-state')),
    state,
  );
  await tester.enterText(
    find.byKey(const ValueKey<String>('uqpay-card-postcode')),
    postcode,
  );
  await tester.pump();
}
