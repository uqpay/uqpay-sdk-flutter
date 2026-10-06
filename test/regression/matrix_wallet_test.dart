import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../sheet/support/sheet_harness.dart';
import '../sheet/support/sheet_screens.dart';
import '../support/fakes.dart';

/// Failure matrix, QR-wallet column (PayNow as the representative wallet): the
/// cells the existing suites did not name a test for, headless and through
/// the sheet. The full matrix is in `doc/testing.md`, "Scenario coverage".
void main() {
  const l10n = UqpayLocalizations();

  UqpayHttpResponse rpm() => jsonResponse(200, intentJson());
  UqpayHttpResponse qr() => jsonResponse(
    200,
    intentJson(status: 'REQUIRES_CUSTOMER_ACTION', nextAction: qrNextAction()),
  );
  UqpayHttpResponse succeeded() =>
      jsonResponse(200, intentJson(status: 'SUCCEEDED'));

  group('failure matrix, wallet, headless', () {
    late PaymentsHarness h;
    setUp(() => h = PaymentsHarness());

    test('success: QR served, polled to SUCCEEDED → Completed, the QR is '
        'surfaced on status and the pin released', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(qr())
        ..enqueue(qr())
        ..enqueue(succeeded());
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: walletConfirmRequest(),
      );
      final events = <UqpayPaymentStatus>[];
      flow.status.listen(events.add);

      final result = await flow.confirm();

      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(1));
      expect(
        events.map((e) => e.nextAction?.type),
        contains(UqpayNextActionType.displayQrCode),
      );
      expect(h.storage.entries, isEmpty);
    });

    test('user cancel before anything was sent → Canceled(reason)', () async {
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: walletConfirmRequest(),
      )..cancel(UqpayCancelReason.userTappedCancel);
      final result = await flow.result;
      expect(
        (result as UqpayPaymentCanceled).reason,
        UqpayCancelReason.userTappedCancel,
      );
      expect(h.http.requests, isEmpty);
    });

    test('network timeout ×4, nothing landed → Failed(timeout), retryable, '
        'one key, pin kept', () async {
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
      final result = await h.payments.confirm('pi_123', walletConfirmRequest());
      final failed = result as UqpayPaymentFailed;
      expect(failed.error.code, UqpayErrorCode.timeout);
      expect(failed.error.isRetryable, isTrue);
      expect(h.confirms, hasLength(4));
      expect(
        h.confirms.map((r) => r.headers['x-idempotency-key']).toSet(),
        hasLength(1),
      );
      expect(h.storage.entries, hasLength(1));
    });

    test('server 5xx ×4, then the reconcile read shows the QR was paid → '
        'Completed, never a false failure', () async {
      h.http.enqueue(rpm());
      for (var i = 0; i < 4; i++) {
        h.http.enqueue(
          jsonResponse(503, <String, Object?>{'message': 'try later'}),
        );
      }
      h.http.enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', walletConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(4));
    });

    test('malformed 2xx: no replay; the reconcile read decides', () async {
      h.http
        ..enqueue(rpm())
        ..enqueue(jsonResponse(200, '<html>oops</html>'))
        ..enqueue(qr())
        ..enqueue(succeeded());
      final result = await h.payments.confirm('pi_123', walletConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(h.confirms, hasLength(1), reason: 'a processed 2xx is not resent');
    });

    test(
      'unknown error code (the sandbox system_error for a wallet that is '
      'not enabled) is preserved as Failed, never thrown, never a QR',
      () async {
        h.http
          ..enqueue(rpm())
          ..enqueue(
            jsonResponse(400, <String, Object?>{
              'code': 'system_error',
              'message': 'x',
            }),
          );
        final result = await h.payments.confirm(
          'pi_123',
          walletConfirmRequest(),
        );
        final failed = result as UqpayPaymentFailed;
        expect(failed.error.code.isUnknown, isTrue);
        expect(failed.error.code.raw, 'system_error');
        expect(h.confirms, hasLength(1));
      },
    );

    test(
      'double confirm() on one wallet flow → one request, same result',
      () async {
        h.http
          ..enqueue(rpm())
          ..enqueue(qr())
          ..enqueue(succeeded());
        final flow = h.payments.createFlow(
          intentId: 'pi_123',
          request: walletConfirmRequest(),
        );
        final a = flow.confirm();
        final b = flow.confirm();
        expect(identical(await a, await b), isTrue);
        expect(h.confirms, hasLength(1));
      },
    );

    test('process death mid-confirm (simulated): the pin outlives the '
        'process and a relaunch reconciles it without re-confirming', () async {
      h.http
        ..enqueue(rpm())
        // The process "dies" with the wallet confirm unanswered.
        ..enqueueHandler((_) => Completer<UqpayHttpResponse>().future);
      final flow = h.payments.createFlow(
        intentId: 'pi_123',
        request: walletConfirmRequest(),
      );
      unawaited(flow.confirm());
      await pumpEventQueue();
      expect(h.confirms, hasLength(1));

      // Relaunch: a fresh UqpayPayments over the SAME persisted storage.
      final relaunched = PaymentsHarness();
      final payments2 = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(const <String>['tok']),
        httpClient: relaunched.http,
        clock: FakeClock(),
        storage: h.storage,
      );
      expect(await payments2.unresolvedIntentIds(), ['pi_123']);

      // The customer scanned before the kill: the server says SUCCEEDED.
      relaunched.http.enqueue(succeeded());
      final reconciled = await payments2.reconcileUnresolved();
      expect(reconciled.single, isA<UqpayPaymentCompleted>());
      expect(await payments2.unresolvedIntentIds(), isEmpty);
      expect(relaunched.confirms, isEmpty, reason: 'reconcile never confirms');
    });

    test('process death mid-confirm (simulated): a re-confirm of the same '
        'wallet after relaunch sends the SAME idempotency key', () async {
      h.http
        ..enqueue(rpm())
        ..enqueueHandler((_) => Completer<UqpayHttpResponse>().future);
      unawaited(
        h.payments
            .createFlow(intentId: 'pi_123', request: walletConfirmRequest())
            .confirm(),
      );
      await pumpEventQueue();
      final key = h.confirms.single.headers['x-idempotency-key'];

      final relaunched = PaymentsHarness();
      final payments2 = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(const <String>['tok']),
        httpClient: relaunched.http,
        clock: FakeClock(),
        storage: h.storage,
      );
      relaunched.http
        ..enqueue(rpm())
        ..enqueue(qr())
        ..enqueue(succeeded());
      final result = await payments2.confirm('pi_123', walletConfirmRequest());
      expect(result, isA<UqpayPaymentCompleted>());
      expect(relaunched.confirms.single.headers['x-idempotency-key'], key);
    });
  });

  group('failure matrix, wallet, sheet', () {
    /// Answers every request with [body], re-evaluated per request.
    void serveLive(SheetHarness harness, Map<String, Object?> Function() body) {
      for (var i = 0; i < 400; i++) {
        harness.http.enqueueHandler((_) => jsonResponse(200, body()));
      }
    }

    Future<void> advance(
      WidgetTester tester,
      SheetHarness harness,
      Duration by,
    ) async {
      for (var s = 0; s < by.inSeconds; s++) {
        harness.clock.advance(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pumpUntilIdle(tester);
    }

    Map<String, Object?> qrIntent(int minutes) => intentJson(
      status: 'REQUIRES_CUSTOMER_ACTION',
      nextAction: qrNextActionExpiringIn(minutes),
    )..['available_payment_method_types'] = <Object?>['card', 'paynow'];

    Future<void> openList(WidgetTester tester, SheetHarness harness) async {
      harness.http
        ..enqueue(rpm()) // load
        ..enqueue(rpm()); // guard
      await pumpEmbeddedSheet(tester, harness);
      await pumpUntilIdle(tester);
    }

    testWidgets('success: the QR is shown, the customer pays, the poll sees '
        'SUCCEEDED → success screen, Completed on Done', (tester) async {
      final harness = SheetHarness();
      var paid = false;
      await openList(tester, harness);
      serveLive(
        harness,
        () => paid ? intentJson(status: 'SUCCEEDED') : qrIntent(10),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-method-paynow')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(l10n.cancel), findsOneWidget, reason: 'QR screen');
      expect(harness.results, isEmpty, reason: 'a QR alone is not success');

      paid = true;
      await advance(tester, harness, const Duration(seconds: 30));

      expect(find.text(l10n.successTitle), findsOneWidget);
      await tester.tap(find.text(l10n.done));
      await pumpUntilIdle(tester);
      expect(harness.results.single, isA<UqpayPaymentCompleted>());
      expect(harness.confirms, hasLength(1));
    });

    testWidgets('double-tap: two taps on the wallet tile in one frame send '
        'exactly one confirm', (tester) async {
      final harness = SheetHarness();
      await openList(tester, harness);
      serveLive(harness, () => qrIntent(10));
      final tile = find.byKey(const ValueKey<String>('uqpay-method-paynow'));
      final center = tester.getCenter(tile);
      await tester.tapAt(center);
      await tester.tapAt(center);
      await pumpUntilIdle(tester);
      await tester.tapAt(center);
      await pumpUntilIdle(tester);
      expect(harness.confirms, hasLength(1));
      expect(harness.flows, hasLength(1));
    });

    testWidgets('app backgrounded on the QR screen: nothing is sent while '
        'paused; on resume the sheet reads the intent and shows the result', (
      tester,
    ) async {
      final harness = SheetHarness();
      var paid = false;
      await openList(tester, harness);
      serveLive(
        harness,
        () => paid ? intentJson(status: 'SUCCEEDED') : qrIntent(10),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-method-paynow')),
      );
      await pumpUntilIdle(tester);

      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpUntilIdle(tester);
      final readsWhilePaused = harness.reads.length;
      // The customer switches to the wallet app and pays.
      paid = true;
      await advance(tester, harness, const Duration(seconds: 60));
      expect(harness.reads, hasLength(readsWhilePaused));
      expect(harness.results, isEmpty);

      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntilIdle(tester);

      expect(harness.reads.length, greaterThan(readsWhilePaused));
      expect(find.text(l10n.successTitle), findsOneWidget);
    });

    testWidgets('QR expiry: when expires_at passes the sheet shows "code '
        'expired" and delivers Pending (cause timeout, last status '
        'REQUIRES_CUSTOMER_ACTION) on Done, and polling stops', (tester) async {
      final harness = SheetHarness();
      var paid = false;
      await openList(tester, harness);
      serveLive(
        harness,
        () => paid ? intentJson(status: 'SUCCEEDED') : qrIntent(2),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('uqpay-method-paynow')),
      );
      await pumpUntilIdle(tester);
      expect(find.text(l10n.qrExpiredTitle), findsNothing);

      await advance(tester, harness, const Duration(minutes: 2, seconds: 1));

      expect(find.text(l10n.qrExpiredTitle), findsOneWidget);
      expect(find.text(l10n.qrExpiredBody), findsOneWidget);
      // Embedded sheet: the result goes out when the customer closes it.
      expect(harness.results, isEmpty);
      final readsAtExpiry = harness.reads.length;
      await advance(tester, harness, const Duration(seconds: 60));
      expect(
        harness.reads,
        hasLength(readsAtExpiry),
        reason: 'the flow is finished: no polling after expiry',
      );

      await tester.tap(find.text(l10n.done));
      await pumpUntilIdle(tester);

      final result = harness.results.single;
      expect(result, isA<UqpayPaymentPending>());
      final pending = result as UqpayPaymentPending;
      expect(pending.intentId, kIntentId);
      expect(
        pending.lastKnownStatus,
        UqpayIntentStatus.requiresCustomerAction,
      );
      // The expiry is named: a timeout cause with the outcome unknown, so a
      // merchant can tell it from a customer closing the sheet.
      expect(pending.cause?.code, UqpayErrorCode.timeout);
      expect(pending.cause?.isOutcomeUnknown, isTrue);
      expect(harness.flows.single.isDone, isTrue);

      // reconcile() reads the intent once; a last-second scan that
      // settled after the expiry is reported as Completed.
      paid = true;
      final reconciled = await pending.reconcile();
      expect(reconciled, isA<UqpayPaymentCompleted>());
      expect(harness.confirms, hasLength(1), reason: 'never re-confirmed');
    });
  });
}
