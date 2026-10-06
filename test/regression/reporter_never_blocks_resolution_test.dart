// Regression: the SDK's own error reporter must never be able to prevent the
// merchant's Future from completing.
//
// `FlutterError.reportError` is not total — formatting a `package:stack_trace`
// async stack (what `flutter test` produces, and anything that leaves
// `FlutterError.demangleStackTrace` unset) trips an assertion inside
// `StackFrame.fromStackTraceLine`. The payment flow's top-level catch used to
// report first and resolve second, so a throwing reporter skipped the resolve
// and the payment hung forever in debug builds.
//
// Guarantees: every flow terminates, and its result is delivered exactly
// once.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

import '../support/fakes.dart';

void main() {
  test(
    'an unexpected throw inside the flow still resolves the merchant future',
    () async {
      final clock = ManualClock();
      final harness = PaymentsHarness(clock: clock);

      // A raw, unclassified error at the client seam stands in for any
      // unexpected internal throw (a plugin misbehaving, an SDK bug).
      harness.http.enqueueHandler(
        (_) => jsonResponse(200, intentJson()),
      );
      for (var i = 0; i < 10; i++) {
        harness.http.enqueueError(StateError('unexpected internal failure'));
      }

      final future = harness.payments.confirm('pi_test', cardConfirmRequest());

      var settled = false;
      unawaited(future.then((_) => settled = true));
      for (var i = 0; i < 100 && !settled; i++) {
        await Future<void>.delayed(Duration.zero);
        clock.advance(const Duration(seconds: 5));
      }

      final result = await future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('flow never resolved'),
      );
      // The throw happened on the confirm send, after it left the device:
      // Pending (outcome unknown), never a Failed that invites a re-charge.
      expect(result, isA<UqpayPaymentPending>());
    },
  );
}
