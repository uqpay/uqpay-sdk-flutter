// When neither the intent nor the next_action carries a `return_url`, the flow
// must still present the challenge — using a sentinel URL that matches no
// http(s) navigation, so an app-scheme return still ends the browser step.
//
// Without this, a server that omits `return_url` would leave the challenge
// unpresentable.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

import '../support/fakes.dart';

class _RecordingPresenter implements UqpayChallengePresenter {
  final List<UqpayChallengeRequest> requests = <UqpayChallengeRequest>[];

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    requests.add(request);
    return const UqpayChallengeOutcome.dismissedByUser();
  }
}

Map<String, Object?> _redirectWithoutReturnUrl() => <String, Object?>{
  'type': 'redirect_to_url',
  'redirect_to_url': <String, Object?>{'url': 'https://acs.example/challenge'},
};

void main() {
  test(
    'a challenge with no return_url anywhere still presents, via a sentinel',
    () async {
      final clock = ManualClock();
      final harness = PaymentsHarness(clock: clock);
      final presenter = _RecordingPresenter();

      // The intent itself carries no return_url either.
      final intent = Map<String, Object?>.from(
        intentJson(
          status: 'REQUIRES_CUSTOMER_ACTION',
          nextAction: _redirectWithoutReturnUrl(),
        ),
      )..remove('return_url');

      for (var i = 0; i < 60; i++) {
        harness.http.enqueue(jsonResponse(200, intent));
      }

      final flow = harness.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
        challengePresenter: presenter,
      );
      final future = flow.confirm();

      var settled = false;
      unawaited(future.then((_) => settled = true));
      for (var i = 0; i < 400 && !settled; i++) {
        await Future<void>.delayed(Duration.zero);
        clock.advance(const Duration(seconds: 10));
      }
      await future;

      expect(
        presenter.requests,
        isNotEmpty,
        reason: 'the challenge must still be presented',
      );
      expect(presenter.requests.single.returnUrl.scheme, 'uqpay-return');
    },
  );
}
