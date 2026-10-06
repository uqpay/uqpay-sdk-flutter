import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

import '../support/fakes.dart';

/// A scripted [UqpayChallengePresenter]: records every request and answers
/// from a queue (the last outcome repeats).
class FakeChallengePresenter implements UqpayChallengePresenter {
  FakeChallengePresenter(this.outcomes);

  final List<UqpayChallengeOutcome> outcomes;
  final List<UqpayChallengeRequest> requests = <UqpayChallengeRequest>[];

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) async {
    requests.add(request);
    final index = requests.length - 1;
    return outcomes[index < outcomes.length ? index : outcomes.length - 1];
  }
}

/// A presenter that (incorrectly) throws instead of returning `failed`.
class ThrowingChallengePresenter implements UqpayChallengePresenter {
  int calls = 0;

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) {
    calls++;
    throw StateError('presenter exploded');
  }
}

/// The flow hands a redirect `next_action` to the presenter once,
/// then resolves the **server's** status — the presenter's outcome is only
/// the trigger for an immediate re-query. Covers the server-status matrix
/// after a challenge, and the 3DS failure code: a 3DS failure surfaces as
/// Failed with a 3DS-specific error code, not unknown.
void main() {
  late PaymentsHarness h;

  setUp(() {
    h = PaymentsHarness();
  });

  UqpayHttpResponseAliases aliases() => (
    rpm: jsonResponse(200, intentJson()),
    challenge: jsonResponse(
      200,
      intentJson(
        status: 'REQUIRES_CUSTOMER_ACTION',
        nextAction: redirectNextAction(),
      ),
    ),
    succeeded: jsonResponse(200, intentJson(status: 'SUCCEEDED')),
  );

  UqpayPaymentFlow flow(
    UqpayChallengePresenter presenter, {
    Duration outcomeDeadline = const Duration(minutes: 5),
  }) => h.payments.createFlow(
    intentId: 'pi_123',
    request: cardConfirmRequest(),
    outcomeDeadline: outcomeDeadline,
    challengePresenter: presenter,
  );

  group('presenter outcome × server status', () {
    test('returned + SUCCEEDED -> Completed, one immediate re-query', () async {
      final a = aliases();
      h.http
        ..enqueue(a.rpm) // terminal-intent guard
        ..enqueue(a.challenge) // confirm -> RCA + redirect_to_url
        ..enqueue(a.succeeded); // the immediate post-challenge read
      final presenter = FakeChallengePresenter([
        UqpayChallengeOutcome.returned(Uri.parse('myapp://payment?ok=1')),
      ]);

      final result = await flow(presenter).confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(presenter.requests, hasLength(1));
      final request = presenter.requests.single;
      expect(request.intentId, 'pi_123');
      expect(
        request.action.type,
        UqpayNextActionType.redirectToUrl,
      );
      expect(
        request.returnUrl,
        Uri.parse('myapp://payment'),
        reason: 'the return_url echoed inside the action is the sentinel',
      );
      // guard + exactly one post-challenge read; no poll wait in between.
      expect(h.reads, hasLength(2));
      expect(h.confirms, hasLength(1));
    });

    test('returned + FAILED(3ds_failed) -> Failed with threeDsFailed, '
        'never unknown', () async {
      final a = aliases();
      h.http
        ..enqueue(a.rpm)
        ..enqueue(a.challenge)
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'FAILED',
              attempt: failedAttempt('3ds_failed'),
            ),
          ),
        );
      final presenter = FakeChallengePresenter([
        UqpayChallengeOutcome.returned(Uri.parse('myapp://payment')),
      ]);

      final result = await flow(presenter).confirm();

      expect(result, isA<UqpayPaymentFailed>());
      final failed = result as UqpayPaymentFailed;
      expect(failed.error.code, UqpayErrorCode.threeDsFailed);
      expect(failed.error.code.raw, '3ds_failed');
      expect(failed.error.code.isUnknown, isFalse);
    });

    test(
      'returned + REQUIRES_PAYMENT_METHOD with a 3ds_failed attempt '
      '(abandoned challenge) -> Failed(threeDsFailed)',
      () async {
        final a = aliases();
        h.http
          ..enqueue(a.rpm)
          ..enqueue(a.challenge)
          ..enqueue(
            jsonResponse(
              200,
              intentJson(attempt: failedAttempt('3ds_failed')),
            ),
          );
        final presenter = FakeChallengePresenter([
          UqpayChallengeOutcome.returned(Uri.parse('myapp://payment')),
        ]);

        final result = await flow(presenter).confirm();

        expect(result, isA<UqpayPaymentFailed>());
        expect(
          (result as UqpayPaymentFailed).error.code,
          UqpayErrorCode.threeDsFailed,
        );
      },
    );

    test(
      'returned but still REQUIRES_CUSTOMER_ACTION -> keeps polling; the '
      'same action is never presented twice',
      () async {
        final a = aliases();
        h.http
          ..enqueue(a.rpm)
          ..enqueue(a.challenge)
          ..enqueue(a.challenge) // still RCA with the SAME action
          ..enqueue(a.challenge) // and again on the next scheduled poll
          ..enqueue(a.succeeded);
        final presenter = FakeChallengePresenter([
          UqpayChallengeOutcome.returned(Uri.parse('myapp://payment')),
        ]);

        final result = await flow(presenter).confirm();

        expect(result, isA<UqpayPaymentCompleted>());
        expect(presenter.requests, hasLength(1), reason: 'deduped by URL');
        expect(h.reads, hasLength(4));
      },
    );

    test(
      'dismissedByUser -> immediate reconcile; server FAILED decides',
      () async {
        final a = aliases();
        h.http
          ..enqueue(a.rpm)
          ..enqueue(a.challenge)
          ..enqueue(
            jsonResponse(
              200,
              intentJson(
                status: 'FAILED',
                attempt: failedAttempt('3ds_failed'),
              ),
            ),
          );
        final presenter = FakeChallengePresenter([
          const UqpayChallengeOutcome.dismissedByUser(),
        ]);

        final result = await flow(presenter).confirm();

        expect(result, isA<UqpayPaymentFailed>());
        expect(
          (result as UqpayPaymentFailed).error.code,
          UqpayErrorCode.threeDsFailed,
        );
      },
    );

    test(
      'dismissedByUser -> reconcile; a still-pending server yields Pending '
      'when the budget runs out (never a fabricated cancel)',
      () async {
        final a = aliases();
        final pending = jsonResponse(200, intentJson(status: 'PENDING'));
        h.http
          ..enqueue(a.rpm)
          ..enqueue(a.challenge)
          ..enqueue(pending) // immediate post-dismiss read
          ..enqueue(pending); // one scheduled poll before the budget dies
        final presenter = FakeChallengePresenter([
          const UqpayChallengeOutcome.dismissedByUser(),
        ]);

        final result = await flow(
          presenter,
          outcomeDeadline: const Duration(seconds: 4),
        ).confirm();

        expect(result, isA<UqpayPaymentPending>());
        expect(
          (result as UqpayPaymentPending).lastKnownStatus,
          UqpayIntentStatus.pending,
        );
      },
    );

    test('timedOut -> immediate reconcile; server SUCCEEDED wins', () async {
      final a = aliases();
      h.http
        ..enqueue(a.rpm)
        ..enqueue(a.challenge)
        ..enqueue(a.succeeded);
      final presenter = FakeChallengePresenter([
        const UqpayChallengeOutcome.timedOut(),
      ]);

      final result = await flow(presenter).confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(presenter.requests, hasLength(1));
    });

    test(
      'failed presentation -> immediate reconcile; server status wins',
      () async {
        final a = aliases();
        h.http
          ..enqueue(a.rpm)
          ..enqueue(a.challenge)
          ..enqueue(a.succeeded);
        final presenter = FakeChallengePresenter([
          const UqpayChallengeOutcome.failed(
            UqpayError(
              code: UqpayErrorCode.invalidConfiguration,
              developerMessage: 'no webview here',
              userMessage: 'x',
              isRetryable: false,
            ),
          ),
        ]);

        final result = await flow(presenter).confirm();

        expect(result, isA<UqpayPaymentCompleted>());
      },
    );
  });

  group('presentation mechanics', () {
    test(
      'two DIFFERENT challenges are each presented once (chaining)',
      () async {
        final secondAction = <String, Object?>{
          'type': 'redirect_to_url',
          'redirect_to_url': <String, Object?>{
            'url': 'https://acs.example/challenge/step-2',
            'return_url': 'myapp://payment',
          },
        };
        final a = aliases();
        h.http
          ..enqueue(a.rpm)
          ..enqueue(a.challenge)
          ..enqueue(
            jsonResponse(
              200,
              intentJson(
                status: 'REQUIRES_CUSTOMER_ACTION',
                nextAction: secondAction,
              ),
            ),
          )
          ..enqueue(a.succeeded);
        final presenter = FakeChallengePresenter([
          UqpayChallengeOutcome.returned(Uri.parse('myapp://payment')),
        ]);

        final result = await flow(presenter).confirm();

        expect(result, isA<UqpayPaymentCompleted>());
        expect(presenter.requests, hasLength(2));
        expect(
          presenter.requests[0].action.redirectToUrl?.url,
          'https://acs.example/challenge',
        );
        expect(
          presenter.requests[1].action.redirectToUrl?.url,
          'https://acs.example/challenge/step-2',
        );
      },
    );

    test('a redirect_iframe action is presented; the intent return_url is '
        'the sentinel', () async {
      final iframeAction = <String, Object?>{
        'type': 'redirect_iframe',
        'redirect_iframe': <String, Object?>{
          'iframe':
              '<form method="POST" action="https://acs.example/f"> </form>',
        },
      };
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: iframeAction,
            ),
          ),
        )
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final presenter = FakeChallengePresenter([
        UqpayChallengeOutcome.returned(Uri.parse('myapp://payment')),
      ]);

      final result = await flow(presenter).confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(presenter.requests, hasLength(1));
      expect(
        presenter.requests.single.action.type,
        UqpayNextActionType.redirectIframe,
      );
      expect(
        presenter.requests.single.returnUrl,
        Uri.parse('myapp://payment'),
        reason: 'falls back to the intent-level return_url',
      );
    });

    test('a QR action is never handed to the challenge presenter', () async {
      h.http
        ..enqueue(jsonResponse(200, intentJson()))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextAction(),
            ),
          ),
        )
        ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final presenter = FakeChallengePresenter([
        const UqpayChallengeOutcome.dismissedByUser(),
      ]);

      final result = await flow(presenter).confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(presenter.requests, isEmpty);
    });

    test('awaitOutcome presents a challenge the guard read served', () async {
      final a = aliases();
      h.http
        ..enqueue(a.challenge) // guard: already RCA + redirect
        ..enqueue(a.succeeded);
      final presenter = FakeChallengePresenter([
        UqpayChallengeOutcome.returned(Uri.parse('myapp://payment')),
      ]);
      final f = h.payments.createFlow(
        intentId: 'pi_123',
        challengePresenter: presenter,
      );

      final result = await f.awaitOutcome();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(presenter.requests, hasLength(1));
      expect(h.confirms, isEmpty);
    });

    test('a throwing presenter is reported, never breaks the flow, and the '
        'server still decides', () async {
      final a = aliases();
      h.http
        ..enqueue(a.rpm)
        ..enqueue(a.challenge)
        ..enqueue(a.succeeded);
      final presenter = ThrowingChallengePresenter();
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      try {
        final result = await flow(presenter).confirm();
        expect(result, isA<UqpayPaymentCompleted>());
      } finally {
        FlutterError.onError = previous;
      }
      expect(presenter.calls, 1);
      expect(reported, hasLength(1));
      expect(reported.single.exception, isA<StateError>());
    });

    test('without a presenter the action is only surfaced on status '
        '(unchanged behaviour)', () async {
      final a = aliases();
      h.http
        ..enqueue(a.rpm)
        ..enqueue(a.challenge)
        ..enqueue(a.succeeded);
      final f = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      final phases = <UqpayPaymentPhase>[];
      f.status.listen((s) => phases.add(s.phase));

      final result = await f.confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(phases, contains(UqpayPaymentPhase.awaitingCustomerAction));
    });
  });
}

/// Named canned responses for the common script.
typedef UqpayHttpResponseAliases = ({
  UqpayHttpResponse rpm,
  UqpayHttpResponse challenge,
  UqpayHttpResponse succeeded,
});
