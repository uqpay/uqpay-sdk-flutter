import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import '../three_ds/support/fake_webview_platform.dart';

/// A presenter that never completes on its own: it only ends when the flow
/// signals [UqpayChallengeRequest.cancelled] (or never, when [ignoreCancel]).
class _HangingPresenter implements UqpayChallengePresenter {
  _HangingPresenter({this.ignoreCancel = false});

  final bool ignoreCancel;
  final List<UqpayChallengeRequest> requests = <UqpayChallengeRequest>[];
  bool cancelSeen = false;

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    requests.add(request);
    unawaited(request.cancelled!.then((_) => cancelSeen = true));
    if (ignoreCancel) {
      return Completer<UqpayChallengeOutcome>().future;
    }
    await request.cancelled;
    return const UqpayChallengeOutcome.dismissedByUser();
  }
}

/// 3DS flow-side regressions: the flow tells the
/// presenter to close when it finishes, and bounds `present` on the SDK
/// clock so a presenter that never completes cannot hang the payment.
void main() {
  Map<String, Object?> challengeIntent() => intentJson(
    status: 'REQUIRES_CUSTOMER_ACTION',
    nextAction: redirectNextAction(),
  );

  group('flow.cancel() closes the challenge', () {
    test('the request carries a cancellation signal that cancel() '
        'completes; the result is Pending', () async {
      // ManualClock: the presentation bound must not fire on its own here.
      final h = PaymentsHarness(clock: ManualClock());
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, challengeIntent()));
      final presenter = _HangingPresenter();
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
        challengePresenter: presenter,
      );
      final result = flow.confirm();
      await pumpEventQueue();
      expect(presenter.requests, hasLength(1));
      expect(presenter.cancelSeen, isFalse);

      flow.cancel(UqpayCancelReason.userDismissed);

      expect(await result, isA<UqpayPaymentPending>());
      await pumpEventQueue();
      expect(presenter.cancelSeen, isTrue);
    });

    testWidgets('the real webview page is popped when the flow is '
        'cancelled (embedded sheet disposal takes this path)', (
      tester,
    ) async {
      final platform = FakeWebViewPlatform.install();
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      final h = PaymentsHarness(clock: ManualClock());
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, challengeIntent()));
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
        challengePresenter: UqpayWebviewChallengePresenter(
          navigator: () => key.currentState!,
          clock: ManualClock(),
        ),
      );
      UqpayPaymentResult? result;
      unawaited(flow.confirm().then((r) => result = r));
      await tester.pumpAndSettle();
      expect(find.byType(UqpayChallengePage), findsOneWidget);

      flow.cancel(UqpayCancelReason.userDismissed);
      await tester.pumpAndSettle();

      expect(result, isA<UqpayPaymentPending>());
      expect(
        find.byType(UqpayChallengePage),
        findsNothing,
        reason: 'no live 3DS page left with nobody listening',
      );
      expect(platform.last.clearCacheCalls, 1);
      expect(h.confirms, hasLength(1));
    });
  });

  group('present() is bounded on the injected clock', () {
    test('a presenter that never completes is closed after 2 x timeout and '
        'the server decides', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, challengeIntent()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final presenter = _HangingPresenter(ignoreCancel: true);
      UqpayPaymentResult? result;
      unawaited(
        h.payments
            .createFlow(
              intentId: 'pi_123',
              request: cardConfirmRequest(),
              challengePresenter: presenter,
            )
            .confirm()
            .then((r) => result = r),
      );
      await pumpEventQueue();
      expect(presenter.requests, hasLength(1));
      final bound = UqpayChallengeRequest.defaultTimeout * 2;

      clock.advance(bound - const Duration(seconds: 1));
      await pumpEventQueue();
      expect(result, isNull);
      expect(presenter.cancelSeen, isFalse);

      clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(presenter.cancelSeen, isTrue, reason: 'told to close its UI');
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.reads, hasLength(2), reason: 'guard + one post-bound read');
      expect(clock.pendingTimers, 0);
    });

    test('paused time does not count: an expiry while paused waits for '
        'resume and re-arms in full', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, challengeIntent()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final presenter = _HangingPresenter(ignoreCancel: true);
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
        challengePresenter: presenter,
      );
      UqpayPaymentResult? result;
      unawaited(flow.confirm().then((r) => result = r));
      await pumpEventQueue();
      final bound = UqpayChallengeRequest.defaultTimeout * 2;

      flow.pause();
      clock.advance(bound * 3);
      await pumpEventQueue();
      expect(presenter.cancelSeen, isFalse);
      expect(result, isNull);

      flow.resume();
      await pumpEventQueue();
      clock.advance(bound - const Duration(seconds: 1));
      await pumpEventQueue();
      expect(presenter.cancelSeen, isFalse, reason: 'a full fresh bound');

      clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(presenter.cancelSeen, isTrue);
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test('a presenter that completes normally leaves no bound timer', () async {
      final clock = ManualClock();
      final h = PaymentsHarness(clock: clock);
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(jsonResponse(200, challengeIntent()))
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final result = await h.payments
          .createFlow(
            intentId: 'pi_123',
            request: cardConfirmRequest(),
            challengePresenter: _ImmediatePresenter(),
          )
          .confirm();
      expect(result, isA<UqpayPaymentCompleted>());
      expect(clock.pendingTimers, 0);
    });
  });
}

class _ImmediatePresenter implements UqpayChallengePresenter {
  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async =>
      UqpayChallengeOutcome.returned(Uri.parse('myapp://payment'));
}
