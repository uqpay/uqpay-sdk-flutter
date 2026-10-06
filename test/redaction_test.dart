import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_api_client.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

import 'support/fakes.dart';

/// No PAN, CVC, expiry or full cardholder name ever reaches a log or
/// a `toString()`. Runs the full card confirm through the real client with a
/// fake transport and a capturing `debugPrint`, across success, decline,
/// 5xx, malformed and transport-failure responses.
void main() {
  const cardholder = 'Ada Lovelace';
  const expiryMonth = '09';
  const expiryYear = '2030';

  late List<String> captured;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    captured = <String>[];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      captured.add(message ?? '');
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
  });

  void expectClean(String text, {String context = ''}) {
    expect(text, isNot(contains(testPan)), reason: 'PAN leaked $context');
    expect(text, isNot(contains(testCvc)), reason: 'CVC leaked $context');
    expect(text, isNot(contains(cardholder)), reason: 'name leaked $context');
    expect(
      text,
      isNot(contains('$expiryMonth/$expiryYear')),
      reason: 'expiry leaked $context',
    );
    expect(
      text,
      isNot(contains('"expiry_year":"$expiryYear"')),
      reason: 'expiry leaked $context',
    );
  }

  test(
    'a card confirm leaks nothing to debugPrint or any toString()',
    () async {
      final http = FakeHttpClient()
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
        ..enqueue(
          jsonResponse(402, {
            'code': 'card_declined',
            'message': 'Declined for card ending 4242',
          }),
        )
        ..enqueue(jsonResponse(500, 'internal error 4242424242424242'))
        ..enqueue(jsonResponse(200, 'not json'))
        ..enqueueError(StateError('transport blew up'));
      final clock = FakeClock();
      final storage = InMemoryKeyValueStore();
      final sdk = sdkWithTokens(['tok']);
      final api = UqpayApiClient(sdk: sdk, httpClient: http, clock: clock);
      final store = IdempotencyStore(
        storage: storage,
        clock: clock,
        namespace: 'sandbox|x|m',
      );

      final request = cardConfirmRequest();
      final pin = await store.obtain(intentId: 'pi_1', body: request.toJson());

      final results = <UqpayApiResult<UqpayPaymentIntent>>[];
      for (var i = 0; i < 4; i++) {
        results.add(
          await api.confirmPaymentIntent(
            id: 'pi_1',
            request: request,
            idempotencyKey: pin.key,
          ),
        );
      }
      // A raw (non-transport) exception from the HTTP layer is a programmer
      // error and propagates; make sure its text is clean too.
      Object? thrown;
      try {
        await api.confirmPaymentIntent(
          id: 'pi_1',
          request: request,
          idempotencyKey: pin.key,
        );
      } on Object catch (e) {
        thrown = e;
      }
      expect(thrown, isA<StateError>());
      expectClean(thrown.toString(), context: 'in thrown error');

      // Sanity: the transport really did carry the PAN, so a leak *could* have
      // happened.
      expect(http.requests.first.body, contains(testPan));
      expect(http.requests.first.body, contains(testCvc));

      // 1. Nothing was printed at all, let alone card data.
      expect(captured, isEmpty);

      // 2. Every toString() the SDK exposes on this path is clean.
      final strings = <String, String>{
        'request': request.toString(),
        'paymentMethod': request.paymentMethod.toString(),
        'card': request.paymentMethod.card.toString(),
        'billing': request.paymentMethod.card!.billing.toString(),
        'address': request.paymentMethod.card!.billing.address.toString(),
        'browserInfo': request.browserInfo.toString(),
        'sdk': sdk.toString(),
        'pin': pin.toString(),
        'clock': clock.toString(),
        for (var i = 0; i < http.requests.length; i++)
          'httpRequest[$i]': http.requests[i].toString(),
        for (var i = 0; i < results.length; i++)
          'result[$i]': switch (results[i]) {
            UqpayApiSuccess<UqpayPaymentIntent>(:final value) =>
              '$value ${value.paymentMethod} ${value.customer}',
            UqpayApiFailure<UqpayPaymentIntent>(:final error) =>
              '$error | ${error.userMessage} | '
                  '${error.developerMessage} | ${error.serverMessage}',
          },
      };
      for (final entry in strings.entries) {
        expectClean(entry.value, context: 'in ${entry.key}');
      }

      // 3. Nothing at rest carries card data.
      for (final entry in storage.entries.entries) {
        expectClean('${entry.key}=${entry.value}', context: 'at rest');
      }

      // 4. The mapped errors are still useful — the redaction cost nothing.
      final decline = (results[1] as UqpayApiFailure<UqpayPaymentIntent>).error;
      expect(decline.code, UqpayErrorCode.cardDeclined);
      expect(decline.serverMessage, 'Declined for card ending 4242');
      final serverError =
          (results[2] as UqpayApiFailure<UqpayPaymentIntent>).error;
      expect(serverError.code, UqpayErrorCode.serverError);
      expect(serverError.serverMessage, contains('[digits]'));
      final malformed =
          (results[3] as UqpayApiFailure<UqpayPaymentIntent>).error;
      expect(malformed.code, UqpayErrorCode.malformedResponse);
    },
  );

  test('ArgumentErrors from card validation never echo the value', () {
    expect(
      () => UqpayCardDetails(
        cardName: cardholder,
        cardNumber: '$testPan ',
        expiryMonth: expiryMonth,
        expiryYear: expiryYear,
        cvc: testCvc,
        billing: const UqpayBillingDetails(),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'toString',
          isNot(contains('4242')),
        ),
      ),
    );
  });

  test('UqpayHttpResponse.toString never includes the body', () {
    final response = UqpayHttpResponse(
      statusCode: 200,
      headers: const {},
      body: '{"card_number":"$testPan","cvc":"$testCvc"}',
    );
    expectClean(response.toString());
  });
}
