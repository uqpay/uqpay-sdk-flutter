import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';
import 'package:uqpay_sdk_flutter_example/src/widgets/result_view.dart';

UqpayPaymentIntent _intent({
  String id = 'pi_test_1',
  String status = 'SUCCEEDED',
}) => UqpayPaymentIntent.fromJson(<String, Object?>{
  'payment_intent_id': id,
  'intent_status': status,
  'amount': '8.98',
  'currency': 'USD',
});

Future<void> _pump(
  WidgetTester tester,
  UqpayPaymentResult result, {
  void Function(String intentId)? onReconcile,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ResultView(result: result, onReconcile: onReconcile),
      ),
    ),
  ),
);

void main() {
  testWidgets('completed renders the intent and its status', (tester) async {
    await _pump(tester, UqpayPaymentCompleted(intent: _intent()));

    expect(find.byKey(const Key('result-completed')), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('pi_test_1'), findsOneWidget);
    expect(find.text('SUCCEEDED'), findsOneWidget);
    // The amount is rendered from the wire string, never rescaled.
    expect(find.textContaining('"8.98" USD'), findsOneWidget);
    expect(find.byKey(const Key('reconcile-button')), findsNothing);
  });

  testWidgets('failed renders the whole error contract', (tester) async {
    await _pump(
      tester,
      const UqpayPaymentFailed(
        intentId: 'pi_test_2',
        error: UqpayError(
          code: UqpayErrorCode.cardDeclined,
          developerMessage: 'issuer declined (do_not_honor)',
          userMessage: 'Your card was declined.',
          isRetryable: false,
          traceId: 'trace-abc',
          httpStatus: 402,
          serverCode: 'card_declined',
        ),
      ),
    );

    expect(find.byKey(const Key('result-failed')), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('card_declined'), findsNWidgets(2));
    expect(find.text('Your card was declined.'), findsOneWidget);
    expect(find.text('no'), findsNWidgets(2));
    expect(find.text('trace-abc'), findsOneWidget);
    expect(find.text('402'), findsOneWidget);
    expect(find.text('issuer declined (do_not_honor)'), findsOneWidget);
  });

  testWidgets('an outcome-unknown failure offers a reconcile', (tester) async {
    final reconciled = <String>[];
    await _pump(
      tester,
      const UqpayPaymentFailed(
        intentId: 'pi_test_5',
        error: UqpayError(
          code: UqpayErrorCode.serverError,
          developerMessage: 'HTTP 502',
          userMessage:
              "We couldn't confirm whether your payment went "
              'through.',
          isRetryable: true,
          isOutcomeUnknown: true,
        ),
      ),
      onReconcile: reconciled.add,
    );

    expect(find.text('yes — reconcile'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reconcile-button')));
    expect(reconciled, <String>['pi_test_5']);
  });

  testWidgets('canceled names who cancelled', (tester) async {
    await _pump(
      tester,
      const UqpayPaymentCanceled(
        intentId: 'pi_test_3',
        reason: UqpayCancelReason.userDismissed,
      ),
    );

    expect(find.byKey(const Key('result-canceled')), findsOneWidget);
    expect(find.text('Canceled'), findsOneWidget);
    expect(find.text('user_dismissed'), findsOneWidget);
    expect(find.textContaining('Nothing was charged'), findsOneWidget);
  });

  testWidgets('pending carries the id and a way to re-query', (tester) async {
    final reconciled = <String>[];
    await _pump(
      tester,
      UqpayPaymentPending(
        intentId: 'pi_test_4',
        lastKnownStatus: UqpayIntentStatus.processing,
        cause: const UqpayError(
          code: UqpayErrorCode.timeout,
          developerMessage: 'outcome deadline exceeded',
          userMessage: 'We could not confirm your payment yet.',
          isRetryable: true,
          isOutcomeUnknown: true,
        ),
        reconcile: () async => UqpayPaymentCompleted(intent: _intent()),
      ),
      onReconcile: reconciled.add,
    );

    expect(find.byKey(const Key('result-pending')), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('pi_test_4'), findsOneWidget);
    expect(find.text('PROCESSING'), findsOneWidget);
    expect(find.text('timeout'), findsOneWidget);
    expect(find.textContaining('NOT a failure'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reconcile-button')));
    expect(reconciled, <String>['pi_test_4']);
  });
}
