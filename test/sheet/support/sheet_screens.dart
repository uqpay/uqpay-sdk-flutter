/// Every screen the drop-in sheet can show, as a scripted scenario driven
/// through the **real** widget and the real flow — no hand-built view stubs.
///
/// Shared by the golden matrix (screen × {light, dark} × {1.0, 2.0}
/// × {LTR, RTL}) and the accessibility guideline tests, so both see
/// exactly what a customer sees.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../../support/fakes.dart';
import 'sheet_harness.dart';

/// A presenter whose challenge never resolves — the sheet stays on its
/// "waiting for verification" screen.
class HangingChallengePresenter implements UqpayChallengePresenter {
  final Completer<UqpayChallengeOutcome> _completer =
      Completer<UqpayChallengeOutcome>();

  @override
  Future<UqpayChallengeOutcome> present(UqpayChallengeRequest request) =>
      _completer.future;
}

/// One scripted screen: the HTTP script to queue before the sheet is pumped,
/// plus the interaction that drives the sheet to the screen afterwards.
class SheetScreenScenario {
  /// Creates a scenario.
  const SheetScreenScenario({
    required this.name,
    required this.script,
    this.drive,
    this.isWeb = false,
    this.presenter,
  });

  /// File-safe screen name, used in golden filenames and test names.
  final String name;

  /// Queues the scenario's HTTP responses.
  final void Function(SheetHarness harness) script;

  /// Optional interaction after the first frames have settled.
  final Future<void> Function(WidgetTester tester, SheetHarness harness)? drive;

  /// Whether the sheet runs as a web build.
  final bool isWeb;

  /// Builds the challenge presenter for this scenario, if it needs one.
  final UqpayChallengePresenter Function()? presenter;
}

/// A never-completing response: the request stays in flight forever.
void _enqueueHanging(SheetHarness harness) => harness.http.enqueueHandler(
  (_) => Completer<UqpayHttpResponse>().future,
);

/// A `display_bank_details` next action.
Map<String, Object?> bankDetailsNextAction() => <String, Object?>{
  'type': 'display_bank_details',
  'display_bank_details': <String, Object?>{
    'bank_name': 'DBS Bank',
    'account_number': '003-900123-4',
    'routing_number': '7171',
  },
};

/// A `display_qr_code` next action expiring [minutes] after the harness
/// clock's start instant (2026-08-18T12:00Z).
Map<String, Object?> qrNextActionExpiringIn(int minutes) => <String, Object?>{
  'type': 'display_qr_code',
  'display_qr_code': <String, Object?>{
    'qr_code':
        '00020101021226540009SG.PAYNOW01012021081234567890301042052040000'
        '53037025802SG5910UQPAY DEMO6009Singapore62070503***6304',
    'expires_at': '2026-08-18T12:${minutes.toString().padLeft(2, '0')}:00Z',
  },
};

Map<String, Object?> _rpm({List<Object?>? methods}) => intentJson()
  ..['available_payment_method_types'] =
      methods ?? <Object?>['card', 'paynow', 'grabpay'];

/// Taps the PayNow tile and lets the confirm run.
Future<void> _payWithPayNow(WidgetTester tester, SheetHarness harness) async {
  await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-paynow')));
  await pumpUntilIdle(tester);
}

/// Every screen, in the order a reviewer reads them.
final List<SheetScreenScenario> sheetScreenScenarios = <SheetScreenScenario>[
  const SheetScreenScenario(name: 'loading', script: _enqueueHanging),
  SheetScreenScenario(
    name: 'load_failed',
    script: (h) => h.http.enqueue(
      jsonResponse(500, <String, Object?>{
        'code': 'internal_error',
        'type': 'api_error',
        'message': '',
      }),
    ),
  ),
  SheetScreenScenario(
    name: 'no_methods',
    script: (h) => h.http.enqueue(
      jsonResponse(200, _rpm(methods: <Object?>['space_credits'])),
    ),
  ),
  SheetScreenScenario(
    name: 'method_list',
    script: (h) => h.http.enqueue(jsonResponse(200, _rpm())),
  ),
  SheetScreenScenario(
    name: 'method_list_web',
    isWeb: true,
    script: (h) => h.http.enqueue(jsonResponse(200, _rpm())),
  ),
  SheetScreenScenario(
    name: 'web_card_only',
    isWeb: true,
    script: (h) =>
        h.http.enqueue(jsonResponse(200, _rpm(methods: <Object?>['card']))),
  ),
  SheetScreenScenario(
    name: 'card_form',
    script: (h) => h.http.enqueue(jsonResponse(200, _rpm())),
    drive: (tester, harness) async {
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await pumpUntilIdle(tester);
    },
  ),
  SheetScreenScenario(
    name: 'card_form_invalid',
    script: (h) => h.http.enqueue(jsonResponse(200, _rpm())),
    drive: (tester, harness) async {
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await pumpUntilIdle(tester);
      await fillValidCard(tester, number: '4242424242424241', expiry: '13/30');
      await tapPay(tester);
      await pumpUntilIdle(tester);
      // Errors first appear on submit (per-field validation); let their
      // fade-in finish so the capture is stable.
      await tester.pump(const Duration(milliseconds: 300));
    },
  ),
  SheetScreenScenario(
    name: 'processing',
    script: (h) {
      h.http
        ..enqueue(jsonResponse(200, _rpm()))
        ..enqueue(jsonResponse(200, _rpm()));
      _enqueueHanging(h);
    },
    drive: _payWithPayNow,
  ),
  SheetScreenScenario(
    name: 'awaiting_outcome',
    script: (h) => h.http
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(jsonResponse(200, intentJson(status: 'PENDING'))),
    drive: _payWithPayNow,
  ),
  SheetScreenScenario(
    name: 'verifying',
    presenter: HangingChallengePresenter.new,
    script: (h) => h.http
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: redirectNextAction(),
          ),
        ),
      ),
    drive: _payWithPayNow,
  ),
  SheetScreenScenario(
    name: 'qr',
    script: (h) => h.http
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: qrNextActionExpiringIn(10),
          ),
        ),
      ),
    drive: _payWithPayNow,
  ),
  SheetScreenScenario(
    name: 'bank_details',
    script: (h) => h.http
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(
        jsonResponse(
          200,
          intentJson(
            status: 'REQUIRES_CUSTOMER_ACTION',
            nextAction: bankDetailsNextAction(),
          ),
        ),
      ),
    drive: _payWithPayNow,
  ),
  SheetScreenScenario(
    name: 'result_success',
    script: (h) => h.http
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED'))),
  ),
  SheetScreenScenario(
    name: 'result_canceled',
    script: (h) => h.http
      ..enqueue(jsonResponse(200, intentJson(status: 'CANCELLED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'CANCELLED'))),
  ),
  SheetScreenScenario(
    name: 'result_failed',
    script: (h) => h.http
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(jsonResponse(200, _rpm()))
      ..enqueue(
        jsonResponse(
          200,
          intentJson(attempt: failedAttempt('payment_declined')),
        ),
      ),
    drive: _payWithPayNow,
  ),
  SheetScreenScenario(
    name: 'result_pending',
    script: (h) {
      h.http
        ..enqueue(jsonResponse(200, _rpm()))
        ..enqueue(jsonResponse(200, _rpm()))
        ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')));
      // The token is rejected on the poll after a refresh: polling cannot
      // help, so the flow reports the honest "not confirmed yet" answer
      // instead of inventing a success or a failure.
      for (var i = 0; i < 4; i++) {
        h.http.enqueue(
          jsonResponse(401, <String, Object?>{'code': 'unauthorized'}),
        );
      }
    },
    drive: (tester, harness) async {
      await _payWithPayNow(tester, harness);
      harness.clock.advance(const Duration(seconds: 30));
      await pumpUntilIdle(tester);
    },
  ),
  SheetScreenScenario(
    name: 'result_qr_expired',
    script: (h) {
      h.http
        ..enqueue(jsonResponse(200, _rpm()))
        ..enqueue(jsonResponse(200, _rpm()));
      for (var i = 0; i < 6; i++) {
        h.http.enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextActionExpiringIn(2),
            ),
          ),
        );
      }
    },
    drive: (tester, harness) async {
      await _payWithPayNow(tester, harness);
      harness.clock.advance(const Duration(minutes: 2, seconds: 1));
      await pumpUntilIdle(tester);
    },
  ),
];
