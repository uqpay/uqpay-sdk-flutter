import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';

/// A merchant may navigate (push, pop, setState) inside the result
/// callback / the `present()` continuation without errors.
void main() {
  const l10n = UqpayLocalizations();
  testWidgets('CB2a: navigate + pop inside the present() continuation', (
    tester,
  ) async {
    final h = SheetHarness();
    h.http
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final nav = Navigator.of(ctx);
    unawaited(
      UqpayPaymentSheet.present(
        ctx,
        payments: h.payments,
        intentId: kIntentId,
        returnUrl: kReturnUrl,
        clock: h.clock,
        isWebPlatform: false,
      ).then((r) {
        h.results.add(r);
        nav
            .push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('THANK-YOU')),
              ),
            )
            .ignore();
      }),
    );
    await pumpUntilIdle(tester, frames: 40);
    await tester.tap(find.text(l10n.done));
    await tester.pumpAndSettle();
    expect(h.results, hasLength(1));
    expect(find.text('THANK-YOU'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CB2b: embedded onResult pops the host route + setState', (
    tester,
  ) async {
    final h = SheetHarness();
    h.http
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const Text('HOME');
            },
          ),
        ),
      ),
    );
    Navigator.of(ctx)
        .push(
          MaterialPageRoute<void>(
            builder: (routeCtx) => Scaffold(
              body: SingleChildScrollView(
                child: UqpayPaymentSheet(
                  payments: h.payments,
                  intentId: kIntentId,
                  returnUrl: kReturnUrl,
                  clock: h.clock,
                  isWebPlatform: false,
                  onResult: (r) {
                    h.results.add(r);
                    Navigator.of(routeCtx).pop();
                  },
                ),
              ),
            ),
          ),
        )
        .ignore();
    await pumpUntilIdle(tester, frames: 40);
    await tester.tap(find.text(l10n.done));
    await tester.pumpAndSettle();
    expect(h.results, hasLength(1));
    expect(find.text('HOME'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
