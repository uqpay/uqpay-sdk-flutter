import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/idempotency_store.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

import 'support/fakes.dart';

/// The headless failure matrix, the terminal-intent guard, dismissal
/// semantics, exactly-once delivery, idempotency, wallet parity, callback
/// safety and hot-restart safety.
///
/// Every test uses the immediate [FakeClock]: delays complete at once, so a
/// flow runs to its result within a few event-loop turns. Schedules are
/// tested with the [ManualClock] in `polling_test.dart`.
void main() {
  late PaymentsHarness h;

  setUp(() {
    h = PaymentsHarness();
  });

  UqpayHttpResponse rpm() => jsonResponse(200, intentJson());
  UqpayHttpResponse succeeded() =>
      jsonResponse(200, intentJson(status: 'SUCCEEDED'));

  /// Asserts the flow finished exactly once, closed its stream, and left no
  /// timer behind (the "no unresolved future" harness).
  Future<UqpayPaymentResult> settle(UqpayPaymentFlow flow) async {
    final result = await flow.result.timeout(const Duration(seconds: 5));
    expect(flow.isDone, isTrue);
    // A second listen on a closed broadcast stream completes immediately.
    await flow.status.drain<void>().timeout(const Duration(seconds: 1));
    return result;
  }

  group('failure matrix — headless cells', () {
    test('success: guard, one confirm, Completed, pin released', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      final phases = <UqpayPaymentPhase>[];
      flow.status.listen((s) => phases.add(s.phase));

      unawaited(flow.confirm());
      final result = await settle(flow);

      expect(result, isA<UqpayPaymentCompleted>());
      final completed = result as UqpayPaymentCompleted;
      expect(completed.intentId, 'pi_123');
      expect(completed.status, UqpayIntentStatus.succeeded);
      expect(h.reads, hasLength(1));
      expect(h.confirms, hasLength(1));
      expect(phases, [
        UqpayPaymentPhase.preparing,
        UqpayPaymentPhase.confirming,
        UqpayPaymentPhase.finished,
      ]);
      expect(h.storage.entries, isEmpty, reason: 'pin released on terminal');
    });

    test('REQUIRES_CAPTURE after confirm is a success', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, intentJson(status: 'REQUIRES_CAPTURE')));
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(
        (result as UqpayPaymentCompleted).status,
        UqpayIntentStatus.requiresCapture,
      );
    });

    test('decline: 2xx with a failed attempt → Failed(cardDeclined)', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              attempt: failedAttempt('do_not_honor'),
            ),
          ),
        );
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentFailed>());
      final failed = result as UqpayPaymentFailed;
      expect(failed.error.code, UqpayErrorCode.cardDeclined);
      expect(failed.error.serverCode, 'do_not_honor');
      expect(failed.intent?.status, UqpayIntentStatus.requiresPaymentMethod);
      expect(h.storage.entries, isEmpty, reason: 'declined: pin released');
    });

    test('insufficient funds via the 4xx envelope', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(
          jsonResponse(402, <String, Object?>{
            'code': 'insufficient_funds',
            'type': 'card_error',
            'message': 'Insufficient funds',
          }),
        );
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      final failed = result as UqpayPaymentFailed;
      expect(failed.error.code, UqpayErrorCode.insufficientFunds);
      expect(failed.error.httpStatus, 402);
      expect(failed.error.isRetryable, isFalse);
      expect(h.confirms, hasLength(1), reason: 'a decline is never replayed');
      expect(h.storage.entries, isEmpty);
    });

    test('user cancel before anything was sent → Canceled(reason)', () async {
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      )..cancel(UqpayCancelReason.userTappedCancel);
      final result = await settle(flow);
      expect(result, isA<UqpayPaymentCanceled>());
      expect(
        (result as UqpayPaymentCanceled).reason,
        UqpayCancelReason.userTappedCancel,
      );
      expect(h.http.requests, isEmpty);
      // confirm() afterwards is a no-op that returns the same result.
      expect(await flow.confirm(), same(result));
      expect(h.http.requests, isEmpty);
    });

    test('cancel while the guard read is in flight → Canceled', () async {
      final guard = Completer<UqpayHttpResponse>();
      h.http.enqueueHandler((_) => guard.future);
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      unawaited(flow.confirm());
      await pumpEventQueue();
      expect(flow.isConfirmInFlight, isFalse);
      flow.cancel(UqpayCancelReason.userDismissed);
      final result = await settle(flow);
      expect(result, isA<UqpayPaymentCanceled>());
      guard.complete(rpm());
      await pumpEventQueue();
      expect(h.confirms, isEmpty, reason: 'nothing sent after a cancel');
    });

    test('cancel-mid-confirm → Pending, never Canceled', () async {
      final hung = Completer<UqpayHttpResponse>();
      h.http
        ..enqueue(rpm())
        ..enqueueHandler((_) => hung.future);
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      unawaited(flow.confirm());
      await pumpEventQueue();
      expect(flow.isConfirmInFlight, isTrue);
      expect(h.storage.entries, hasLength(1), reason: 'pin persisted');

      flow.cancel(UqpayCancelReason.userDismissed);
      final result = await settle(flow);
      expect(result, isA<UqpayPaymentPending>());
      final pending = result as UqpayPaymentPending;
      expect(pending.intentId, 'pi_123');
      expect(pending.lastKnownStatus, UqpayIntentStatus.requiresPaymentMethod);
      expect(pending.cause, isNull);
      expect(h.storage.entries, hasLength(1), reason: 'pin kept while pending');

      // The late answer arrives: the result is unchanged (exactly once) and
      // the pin is tidied because the server settled it.
      hung.complete(succeeded());
      await pumpEventQueue();
      expect(await flow.result, same(result));
      expect(h.storage.entries, isEmpty);
    });

    test(
      'network timeout ×4 with identical key+bytes, then the intent shows '
      'nothing landed → Failed(timeout), retryable, pin kept',
      () async {
        h.http.enqueue(rpm());
        for (var i = 0; i < 4; i++) {
          h.http.enqueueError(
            const UqpayTransportException(
              UqpayTransportFailureKind.timeout,
              'timeout',
            ),
          );
        }
        h.http.enqueue(rpm());
        final result = await h.payments.confirm(
          'pi_123',
          cardConfirmRequest(),
        );

        expect(result, isA<UqpayPaymentFailed>());
        final failed = result as UqpayPaymentFailed;
        expect(failed.error.code, UqpayErrorCode.timeout);
        expect(failed.error.isRetryable, isTrue);
        expect(h.confirms, hasLength(4));
        final keys = h.confirms
            .map((r) => r.headers['x-idempotency-key'])
            .toSet();
        expect(keys, hasLength(1));
        expect(h.confirms.map((r) => r.body).toSet(), hasLength(1));
        final clock = h.clock as FakeClock;
        expect(clock.delays.take(3), [
          const Duration(seconds: 3),
          const Duration(seconds: 6),
          const Duration(seconds: 10),
        ]);
        expect(h.storage.entries, hasLength(1), reason: 'pin kept for retry');
      },
    );

    test('server 5xx ×4 then reconcile GET resolves → Completed', () async {
      h.http.enqueue(rpm());
      for (var i = 0; i < 4; i++) {
        h.http.enqueue(
          jsonResponse(503, <String, Object?>{'message': 'try later'}),
        );
      }
      h.http.enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(4));
      expect(h.reads, hasLength(2));
      expect(h.storage.entries, isEmpty);
    });

    test('malformed 2xx: no replay, reconcile by GET → Completed', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, '<html>oops</html>'))
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(1), reason: 'a processed 2xx is not resent');
    });

    test(
      'malformed 2xx and nothing landed → Failed(malformedResponse)',
      () async {
        h.http
          ..enqueue(rpm())
          ..enqueue(jsonResponse(200, 'garbage'))
          ..enqueue(rpm());
        final result = await h.payments.confirm('pi_123', cardConfirmRequest());
        expect(
          (result as UqpayPaymentFailed).error.code,
          UqpayErrorCode.malformedResponse,
        );
      },
    );

    test('unknown error code is preserved, never thrown', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(
          jsonResponse(400, <String, Object?>{
            'code': 'brand_new_server_code',
            'message': 'x',
          }),
        );
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      final failed = result as UqpayPaymentFailed;
      expect(failed.error.code.isUnknown, isTrue);
      expect(failed.error.code.raw, 'brand_new_server_code');
      expect(failed.error.serverCode, 'brand_new_server_code');
    });

    test('outcome-unknown then the replay resolves → Completed', () async {
      h.http
        ..enqueue(rpm())
        ..enqueueError(
          const UqpayTransportException(
            UqpayTransportFailureKind.socket,
            'reset',
          ),
        )
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(2));
      expect(
        h.confirms[0].headers['x-idempotency-key'],
        h.confirms[1].headers['x-idempotency-key'],
      );
      expect(h.confirms[0].body, h.confirms[1].body);
      expect((h.clock as FakeClock).delays, [const Duration(seconds: 3)]);
    });

    test('double confirm() on one flow → one request, same result', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      final a = flow.confirm();
      final b = flow.confirm();
      final c = flow.awaitOutcome();
      expect(identical(await a, await b), isTrue);
      expect(identical(await a, await c), isTrue);
      expect(h.confirms, hasLength(1));
    });

    test(
      '3DS: RCA after confirm → poll → SUCCEEDED, with action events',
      () async {
        h.http
          ..enqueue(rpm())
          ..enqueue(
            jsonResponse(
              200,
              intentJson(
                status: 'REQUIRES_CUSTOMER_ACTION',
                nextAction: redirectNextAction(),
              ),
            ),
          )
          ..enqueue(
            jsonResponse(
              200,
              intentJson(
                status: 'REQUIRES_CUSTOMER_ACTION',
                nextAction: redirectNextAction(),
              ),
            ),
          )
          ..enqueue(succeeded());
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          request: cardConfirmRequest(),
        );
        final events = <UqpayPaymentStatus>[];
        flow.status.listen(events.add);
        unawaited(flow.confirm());
        final result = await settle(flow);
        expect(result, isA<UqpayPaymentCompleted>());
        expect(h.reads, hasLength(3));
        final action = events.firstWhere(
          (e) => e.phase == UqpayPaymentPhase.awaitingCustomerAction,
        );
        expect(
          action.nextAction?.type,
          UqpayNextActionType.redirectToUrl,
        );
        expect(events.last.phase, UqpayPaymentPhase.finished);
      },
    );

    test(
      '3DS abandoned: poll shows RPM + 3ds_failed → Failed(threeDsFailed)',
      () async {
        h.http
          ..enqueue(rpm())
          ..enqueue(
            jsonResponse(
              200,
              intentJson(
                status: 'REQUIRES_CUSTOMER_ACTION',
                nextAction: redirectNextAction(),
              ),
            ),
          )
          ..enqueue(
            jsonResponse(
              200,
              intentJson(attempt: failedAttempt('3ds_failed')),
            ),
          );
        final result = await h.payments.confirm('pi_123', cardConfirmRequest());
        expect(
          (result as UqpayPaymentFailed).error.code,
          UqpayErrorCode.threeDsFailed,
        );
      },
    );

    test('poll: token rejected after refresh → Pending(cause)', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueue(jsonResponse(401, <String, Object?>{'code': 'unauthorized'}))
        ..enqueue(jsonResponse(401, <String, Object?>{'code': 'unauthorized'}));
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      final pending = result as UqpayPaymentPending;
      expect(pending.cause?.code, UqpayErrorCode.authenticationFailed);
      expect(pending.lastKnownStatus, UqpayIntentStatus.pending);
    });

    test('poll: transient read failures are tolerated', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueueError(
          const UqpayTransportException(UqpayTransportFailureKind.dns, 'dns'),
        )
        ..enqueue(jsonResponse(500, 'boom'))
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test(
      'an SDK bug BEFORE the confirm leaves resolves Failed',
      () async {
        // The guard read itself throws a non-transport error: nothing has been
        // sent, so Failed is honest and the merchant may retry.
        h.http.enqueueError(StateError('boom'));
        final reported = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = previous);
        final result = await h.payments.confirm('pi_123', cardConfirmRequest());
        expect(result, isA<UqpayPaymentFailed>());
        expect(h.confirms, isEmpty);
        expect(reported, hasLength(1));
      },
    );

    test('an SDK bug AFTER the confirm leaves resolves Pending and keeps the '
        'pin', () async {
      h.http
        ..enqueue(rpm())
        ..enqueueError(StateError('boom'));
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentPending>());
      expect(h.confirms, hasLength(1));
      expect(h.storage.entries, isNotEmpty, reason: 'pin kept for reconcile');
      expect(reported, hasLength(1));
    });
  });

  group('terminal-intent guard', () {
    for (final (status, matcher) in <(String, Matcher)>[
      ('SUCCEEDED', isA<UqpayPaymentCompleted>()),
      ('REQUIRES_CAPTURE', isA<UqpayPaymentCompleted>()),
      ('CANCELLED', isA<UqpayPaymentCanceled>()),
      ('CANCELED', isA<UqpayPaymentCanceled>()),
      ('FAILED', isA<UqpayPaymentFailed>()),
    ]) {
      test('$status: returns the terminal result, sends no confirm', () async {
        h.http.enqueue(
          jsonResponse(
            200,
            intentJson(
              status: status,
              attempt: status == 'FAILED' ? failedAttempt('3ds_failed') : null,
            ),
          ),
        );
        final result = await h.payments.confirm(
          'pi_123',
          cardConfirmRequest(),
        );
        expect(result, matcher);
        expect(h.confirms, isEmpty);
        expect(h.reads, hasLength(1));
        switch (result) {
          case UqpayPaymentCanceled(:final reason):
            expect(reason, UqpayCancelReason.intentCancelled);
          case UqpayPaymentFailed(:final error):
            expect(error.code, UqpayErrorCode.threeDsFailed);
          case UqpayPaymentCompleted():
          case UqpayPaymentPending():
            break;
        }
      });
    }

    test(
      'an intent already showing a QR is re-served, not re-confirmed',
      () async {
        h.http
          ..enqueue(
            jsonResponse(
              200,
              intentJson(
                status: 'REQUIRES_CUSTOMER_ACTION',
                nextAction: qrNextAction(),
              ),
            ),
          )
          ..enqueue(succeeded());
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          request: walletConfirmRequest(),
        );
        final events = <UqpayPaymentStatus>[];
        flow.status.listen(events.add);
        unawaited(flow.confirm());
        final result = await settle(flow);
        expect(result, isA<UqpayPaymentCompleted>());
        expect(h.confirms, isEmpty);
        expect(
          events.any(
            (e) =>
                e.phase == UqpayPaymentPhase.awaitingCustomerAction &&
                e.nextAction?.type == UqpayNextActionType.displayQrCode,
          ),
          isTrue,
        );
      },
    );

    test('a PENDING intent is awaited, not re-confirmed', () async {
      h.http
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, isEmpty);
    });

    test('an unknown status fails open: the confirm is sent', () async {
      h.http
        ..enqueue(jsonResponse(200, intentJson(status: 'SOMETHING_NEW')))
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(1));
    });

    test('a failed guard read fails open: the confirm is sent', () async {
      h.http
        ..enqueueError(
          const UqpayTransportException(UqpayTransportFailureKind.dns, 'dns'),
        )
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(1));
    });

    test(
      'awaitOutcome on a fresh intent with nothing attached → Failed',
      () async {
        h.http.enqueue(rpm());
        final result = await h.payments.awaitOutcome('pi_123');
        final failed = result as UqpayPaymentFailed;
        expect(failed.error.code, UqpayErrorCode.invalidPaymentMethod);
        expect(h.confirms, isEmpty);
      },
    );
  });

  group('cancel reasons are distinguishable', () {
    for (final reason in <UqpayCancelReason>[
      UqpayCancelReason.userDismissed,
      UqpayCancelReason.userTappedCancel,
      UqpayCancelReason.merchantCancelled,
      UqpayCancelReason.fromRaw('custom_reason'),
    ]) {
      test('${reason.raw} before send → Canceled(${reason.raw})', () async {
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          request: cardConfirmRequest(),
        )..cancel(reason);
        final result = await settle(flow);
        expect((result as UqpayPaymentCanceled).reason, reason);
        expect(reason.isUnknown, reason.raw == 'custom_reason');
      });
    }

    test('cancel after done is a no-op; result delivered once', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: cardConfirmRequest(),
      );
      var deliveries = 0;
      unawaited(flow.result.then((_) => deliveries++));
      final first = await flow.confirm();
      flow
        ..cancel(UqpayCancelReason.userDismissed)
        ..cancel(UqpayCancelReason.merchantCancelled);
      await pumpEventQueue();
      expect(await flow.result, same(first));
      expect(deliveries, 1);
    });
  });

  group('idempotency', () {
    test(
      'the key is on disk before the confirm leaves and matches it',
      () async {
        String? keyOnDiskAtSend;
        h.http
          ..enqueue(rpm())
          ..enqueueHandler((request) {
            final pins = h.storage.entries.values;
            expect(pins, hasLength(1), reason: 'persisted BEFORE send');
            keyOnDiskAtSend = IdempotencyPin.fromJson(
              _decode(pins.single),
            ).key;
            return succeeded();
          });
        await h.payments.confirm('pi_123', cardConfirmRequest());
        expect(h.confirms.single.headers['x-idempotency-key'], keyOnDiskAtSend);
        expect(keyOnDiskAtSend, matches(RegExp(r'^[0-9a-f-]{36}$')));
      },
    );

    test(
      'a retry of the same logical attempt reuses the key; a changed payload '
      'gets a new one',
      () async {
        // Attempt 1: transport failure all the way → Failed(retryable), pin
        // kept.
        h.http.enqueue(rpm());
        for (var i = 0; i < 4; i++) {
          h.http.enqueueError(
            const UqpayTransportException(
              UqpayTransportFailureKind.socket,
              'x',
            ),
          );
        }
        h.http.enqueue(rpm());
        final first = await h.payments.confirm('pi_123', cardConfirmRequest());
        expect((first as UqpayPaymentFailed).error.isRetryable, isTrue);
        final key1 = h.confirms.first.headers['x-idempotency-key'];

        // Attempt 2: same request → same key.
        h.http
          ..enqueue(rpm())
          ..enqueue(succeeded());
        await h.payments.confirm('pi_123', cardConfirmRequest());
        expect(h.confirms.last.headers['x-idempotency-key'], key1);

        // Attempt 3: different card → different key.
        h.http
          ..enqueue(rpm())
          ..enqueue(succeeded());
        await h.payments.confirm(
          'pi_123',
          cardConfirmRequest(cardNumber: '5555555555554444', cvc: '123'),
        );
        expect(h.confirms.last.headers['x-idempotency-key'], isNot(key1));
      },
    );

    test(
      'reconcileUnresolved resolves a pinned intent and clears it',
      () async {
        h.http.enqueue(rpm());
        for (var i = 0; i < 4; i++) {
          h.http.enqueueError(
            const UqpayTransportException(
              UqpayTransportFailureKind.timeout,
              'x',
            ),
          );
        }
        h.http.enqueue(rpm());
        await h.payments.confirm('pi_123', cardConfirmRequest());
        expect(await h.payments.unresolvedIntentIds(), ['pi_123']);

        h.http.enqueue(succeeded());
        final results = await h.payments.reconcileUnresolved();
        expect(results.single, isA<UqpayPaymentCompleted>());
        expect(await h.payments.unresolvedIntentIds(), isEmpty);
        expect(h.storage.entries, isEmpty);
      },
    );

    test('pins are namespaced per environment', () async {
      h.http.enqueue(rpm());
      for (var i = 0; i < 4; i++) {
        h.http.enqueueError(
          const UqpayTransportException(
            UqpayTransportFailureKind.timeout,
            'x',
          ),
        );
      }
      h.http.enqueue(rpm());
      await h.payments.confirm('pi_123', cardConfirmRequest());

      final other = PaymentsHarness(
        sdk: sdkWithTokens(['t'], environment: UqpayEnvironment.production),
      );
      expect(await other.payments.unresolvedIntentIds(), isEmpty);
    });
  });

  group('wallet / QR parity', () {
    test('card and wallet map the same server payload identically', () async {
      final payload = intentJson(
        attempt: failedAttempt('insufficient_funds', message: 'no money'),
      );
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, payload));
      final card = await h.payments.confirm('pi_123', cardConfirmRequest());

      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, payload));
      final wallet = await h.payments.confirm(
        'pi_123',
        walletConfirmRequest(),
      );

      expect(card, isA<UqpayPaymentFailed>());
      expect(wallet, isA<UqpayPaymentFailed>());
      expect(
        (card as UqpayPaymentFailed).error,
        (wallet as UqpayPaymentFailed).error,
      );
      expect(card.error.code, UqpayErrorCode.insufficientFunds);
    });

    test('card and wallet map the same 4xx envelope identically', () async {
      final envelope = <String, Object?>{
        'code': 'card_declined',
        'type': 'card_error',
        'message': 'nope',
      };
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(402, envelope));
      final card = await h.payments.confirm('pi_123', cardConfirmRequest());
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(402, envelope));
      final wallet = await h.payments.confirm(
        'pi_123',
        walletConfirmRequest(),
      );
      expect(
        (card as UqpayPaymentFailed).error,
        (wallet as UqpayPaymentFailed).error,
      );
    });
  });

  group('callback safety', () {
    test(
      'a throwing status listener is reported and the flow completes',
      () async {
        final reported = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = reported.add;
        addTearDown(() => FlutterError.onError = previous);

        h.http
          ..enqueue(rpm())
          ..enqueue(succeeded());
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          request: cardConfirmRequest(),
        );
        var seen = 0;
        flow.status.listen((_) {
          seen++;
          throw StateError('merchant bug');
        });
        unawaited(flow.confirm());
        final result = await settle(flow);
        expect(result, isA<UqpayPaymentCompleted>());
        expect(seen, 3);
        expect(reported, hasLength(3));
        expect(reported.first.exception, isA<StateError>());
      },
    );
  });

  group('hot restart safety', () {
    test('init → init with a different environment gives fresh handles', () {
      final a = sdkWithTokens(['t']);
      final b = sdkWithTokens(['t'], environment: UqpayEnvironment.production);
      final pa = a.payments;
      final pb = b.payments;
      expect(identical(pa, pb), isFalse);
      expect(pa.sdk, same(a));
      expect(pb.sdk.environment, UqpayEnvironment.production);
      expect(identical(a.payments, pa), isTrue, reason: 'cached per handle');
      pa.close();
      pb.close();
    });

    test('payments without a tokenProvider throws naming the field', () {
      final sdk = UqpaySdk.init(environment: UqpayEnvironment.sandbox);
      expect(
        () => sdk.payments,
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'tokenProvider'),
        ),
      );
    });

    test('an empty intent id or missing request throws ArgumentError', () {
      expect(
        () => h.payments.createFlow(intentId: ' '),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'intentId')),
      );
      expect(
        () => h.payments.createFlow(intentId: 'pi_1').confirm(),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'request')),
      );
      expect(
        () => h.payments.createFlow(
          intentId: 'pi_1',
          outcomeDeadline: Duration.zero,
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'outcomeDeadline'),
        ),
      );
      expect(h.http.requests, isEmpty);
    });
  });
  group('edge cases', () {
    test(
      'cancel while the pin is being written → Canceled, pin released',
      () async {
        final gate = Completer<void>();
        final storage = _GatedStore(gate.future);
        final harness = PaymentsHarness();
        final payments = UqpayPayments.withDependencies(
          sdk: sdkWithTokens(['t']),
          httpClient: harness.http,
          clock: harness.clock,
          storage: storage,
        );
        harness.http.enqueue(rpm());
        final flow = payments.createFlow(
          intentId: 'pi_123',
          request: cardConfirmRequest(),
        );
        unawaited(flow.confirm());
        await pumpEventQueue();
        expect(storage.pendingWrites, 1);
        flow.cancel(UqpayCancelReason.userDismissed);
        gate.complete();
        final result = await settle(flow);
        expect(result, isA<UqpayPaymentCanceled>());
        expect(harness.confirms, isEmpty);
        expect(storage.inner.entries, isEmpty, reason: 'nothing to protect');
      },
    );

    test('status changes while polling are re-emitted; getters', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextAction(),
            ),
          ),
        )
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: walletConfirmRequest(),
      );
      expect(flow.status.isBroadcast, isTrue);
      expect(flow.latestIntent, isNull);
      expect(flow.hasStarted, isFalse);
      final phases = <UqpayPaymentPhase>[];
      flow.status.listen((s) => phases.add(s.phase));
      unawaited(flow.confirm());
      final result = await settle(flow);
      expect(result, isA<UqpayPaymentCompleted>());
      expect(flow.latestIntent?.status, UqpayIntentStatus.succeeded);
      expect(phases, [
        UqpayPaymentPhase.preparing,
        UqpayPaymentPhase.confirming,
        UqpayPaymentPhase.awaitingOutcome,
        UqpayPaymentPhase.awaitingCustomerAction,
        UqpayPaymentPhase.finished,
      ]);
    });

    test('RPM with an expired attempt and no code → declined', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              attempt: <String, Object?>{
                'attempt_id': 'pa_1',
                'attempt_status': 'EXPIRED',
              },
            ),
          ),
        );
      final result = await h.payments.confirm('pi_123', cardConfirmRequest());
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.cardDeclined,
      );
    });

    test(
      'RPM with a live (INITIATED) attempt keeps polling — never a decline; '
      'the budget turns it into Pending',
      () async {
        h.http
          ..enqueue(rpm())
          ..enqueueHandler(
            (_) async => jsonResponse(
              200,
              intentJson(
                attempt: <String, Object?>{
                  'attempt_id': 'pa_1',
                  'attempt_status': 'INITIATED',
                },
              ),
            ),
          );
        final result = await h.payments.confirm(
          'pi_123',
          cardConfirmRequest(),
          outcomeDeadline: const Duration(seconds: 20),
        );
        expect(result, isA<UqpayPaymentPending>());
        expect(h.reads.length, greaterThan(1), reason: 'it polled');
        expect(
          UqpayCancelReason.userDismissed.hashCode,
          UqpayCancelReason.fromRaw('user_dismissed').hashCode,
        );
      },
    );
  });
}

Map<String, Object?> _decode(String json) =>
    jsonDecode(json) as Map<String, Object?>;

/// A store whose writes wait for [gate] before completing.
class _GatedStore implements KeyValueStore {
  _GatedStore(this.gate);
  final Future<void> gate;
  final InMemoryKeyValueStore inner = InMemoryKeyValueStore();
  int pendingWrites = 0;

  @override
  Future<String?> read(String key) => inner.read(key);

  @override
  Future<void> write(String key, String value) async {
    pendingWrites++;
    await gate;
    pendingWrites--;
    await inner.write(key, value);
  }

  @override
  Future<void> remove(String key) => inner.remove(key);

  @override
  Future<Set<String>> keysWithPrefix(String prefix) =>
      inner.keysWithPrefix(prefix);
}
