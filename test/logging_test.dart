import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

import 'support/fakes.dart';

/// `UqpaySdk.init(loggingEnabled:, logHandler:)` — the opt-in diagnostic
/// log (Android `loggingEnabled` parity). What it emits is as important as
/// what it never emits.
void main() {
  UqpaySdk loggingSdk(
    List<String> lines, {
    List<String> tokens = const ['tok'],
  }) {
    var index = 0;
    return UqpaySdk.init(
      environment: UqpayEnvironment.sandbox,
      loggingEnabled: true,
      logHandler: lines.add,
      tokenProvider: () async {
        final token = tokens[index < tokens.length ? index : tokens.length - 1];
        index++;
        return UqpayAuthToken(value: token);
      },
    );
  }

  test('is off by default and the handler is then never called', () async {
    final lines = <String>[];
    final sdk = UqpaySdk.init(
      environment: UqpayEnvironment.sandbox,
      logHandler: lines.add,
      tokenProvider: () async => UqpayAuthToken(value: 'tok'),
    );
    expect(sdk.loggingEnabled, isFalse);
    final h = PaymentsHarness(sdk: sdk);
    h.http.enqueue(jsonResponse(200, intentJson()));
    await h.payments.retrieveIntent('pi_123');
    expect(lines, isEmpty);
  });

  test('logs method, path, status and trace id for every request', () async {
    final lines = <String>[];
    final h = PaymentsHarness(sdk: loggingSdk(lines));
    h.http.enqueue(
      jsonResponse(200, intentJson(), traceId: 'trace-9'),
    );
    await h.payments.retrieveIntent('pi_123');

    expect(
      lines,
      contains(
        '[uqpay] GET /api/v2/payment_intents/pi_123 -> 200 trace=trace-9',
      ),
    );
  });

  test('logs flow phase transitions and the result, by intent id', () async {
    final lines = <String>[];
    final h = PaymentsHarness(sdk: loggingSdk(lines));
    h.http
      ..enqueue(jsonResponse(200, intentJson()))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    final result = await h.payments.confirm('pi_123', cardConfirmRequest());

    expect(result, isA<UqpayPaymentCompleted>());
    expect(lines, contains('[uqpay] flow pi_123: preparing'));
    expect(lines, contains(matches('flow pi_123: confirming')));
    expect(lines, contains('[uqpay] flow pi_123: result completed'));
  });

  test('logs the 401 refresh and a 4xx code, never the body', () async {
    final lines = <String>[];
    final h = PaymentsHarness(sdk: loggingSdk(lines, tokens: ['t1', 't2']));
    h.http
      ..enqueue(jsonResponse(401, {'code': 'unauthorized', 'message': 'x'}))
      ..enqueue(
        jsonResponse(400, {
          'code': 'invalid_payment_method',
          'type': 'invalid_request_error',
          'message': 'invalid billing.email SECRET-BODY-MARKER',
        }),
      );
    await h.payments.retrieveIntent('pi_123');

    expect(lines.join('\n'), contains('401; refreshing the token once'));
    expect(lines.join('\n'), contains('code=invalid_payment_method'));
    expect(lines.join('\n'), isNot(contains('SECRET-BODY-MARKER')));
  });

  test('never emits the PAN, CVC, cardholder name or token', () async {
    final lines = <String>[];
    final h = PaymentsHarness(
      sdk: loggingSdk(lines, tokens: ['tok-secret-value']),
    );
    h.http
      ..enqueue(jsonResponse(200, intentJson()))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    await h.payments.confirm('pi_123', cardConfirmRequest());

    final all = lines.join('\n');
    expect(lines, isNotEmpty);
    expect(all, isNot(contains(testPan)));
    expect(all, isNot(contains(testPan.substring(0, 6))));
    expect(all, isNot(contains(testCvc)));
    expect(all, isNot(contains('tok-secret-value')));
    expect(all, isNot(contains('Bearer')));
    expect(all.toLowerCase(), isNot(contains('lovelace')));
  });

  test('a throwing handler never breaks the request', () async {
    final sdk = UqpaySdk.init(
      environment: UqpayEnvironment.sandbox,
      loggingEnabled: true,
      logHandler: (_) => throw StateError('boom'),
      tokenProvider: () async => UqpayAuthToken(value: 'tok'),
    );
    final h = PaymentsHarness(sdk: sdk);
    h.http.enqueue(jsonResponse(200, intentJson()));
    final read = await h.payments.retrieveIntent('pi_123');
    expect(read, isA<UqpayIntentRetrieved>());
  });
}
