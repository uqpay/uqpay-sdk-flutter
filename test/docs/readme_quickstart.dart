// The README quickstart, as real compiled code.
//
// `readme_quickstart_test.dart` asserts that the ```dart block under
// "## Quickstart" in README.md is byte-identical to the region between the
// BEGIN/END markers below, and importing this file forces the analyzer and
// the compiler over it on every CI run. So the published quickstart cannot
// drift from an API that still compiles.
//
// Everything between the markers is what a merchant copies.
import 'package:flutter/widgets.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// Stands in for the merchant's own backend client in the snippet.
abstract class MyBackend {
  /// Returns the JSON body of your server's "give me a UQPAY token" endpoint.
  Future<Map<String, Object?>> fetchUqpayToken();

  /// Creates a payment intent server-side and returns its id.
  Future<String> createPaymentIntent({
    required String amount,
    required String currency,
    required Uri returnUrl,
  });
}

// --8<-- README QUICKSTART BEGIN
Future<void> checkout(BuildContext context, MyBackend myBackend) async {
  // 1. Point the SDK at an environment. It never holds an API key — your
  //    backend mints a short-lived token and the SDK refreshes it via this
  //    callback.
  final uqpay = UqpaySdk.init(
    environment: UqpayEnvironment.sandbox,
    tokenProvider: () async =>
        UqpayAuthToken.fromJson(await myBackend.fetchUqpayToken()),
  );

  // 2. Create the intent on YOUR server. Amounts are decimal strings in major
  //    units — "8.98", never 898.
  final returnUrl = Uri.parse('myapp://payment-return');
  final intentId = await myBackend.createPaymentIntent(
    amount: '8.98',
    currency: 'SGD',
    returnUrl: returnUrl,
  );

  // 3. Show the sheet. It returns a result; it never throws for a decline.
  if (!context.mounted) return;
  final result = await UqpayPaymentSheet.present(
    context,
    payments: uqpay.payments,
    intentId: intentId,
    returnUrl: returnUrl,
  );

  // 4. Handle every outcome — the switch is exhaustive, so a new SDK version
  //    cannot silently add a case you forgot.
  switch (result) {
    case UqpayPaymentCompleted():
      // A UX signal only. Fulfil after your server re-reads the intent.
      showThankYou();
    case UqpayPaymentFailed(:final error):
      showError(error.userMessage, retryable: error.isRetryable);
    case UqpayPaymentCanceled():
      showCancelled();
    case UqpayPaymentPending(:final intentId):
      // The payment may still succeed. Ask your server later.
      showPending(intentId);
  }
}
// --8<-- README QUICKSTART END

void showThankYou() {}
void showError(String message, {required bool retryable}) {}
void showCancelled() {}
void showPending(String intentId) {}
