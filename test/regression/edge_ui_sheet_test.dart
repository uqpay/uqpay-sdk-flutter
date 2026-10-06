import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/l10n/l10n_fallbacks.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../sheet/support/sheet_harness.dart';
import '../sheet/support/sheet_screens.dart';
import '../support/fakes.dart';

/// Sheet-level edge-case regressions: concurrent finish vs. cancel, embedded
/// sheets, hosts without MaterialLocalizations, blank localisation
/// overrides and appearance merging.
void main() {
  const l10n = UqpayLocalizations();

  Map<String, Object?> offering(List<Object?> methods, {String? id}) {
    final json = intentJson()..['available_payment_method_types'] = methods;
    if (id != null) {
      json['payment_intent_id'] = id;
    }
    return json;
  }

  group('a finishing flow is never reported as Canceled', () {
    testWidgets('cancel on the QR screen while the SUCCEEDED result is still '
        'being housekept delivers Completed', (tester) async {
      final harness = SheetHarness();
      final store = _GatedRemoveStore();
      final payments = TrackingPayments(
        sdk: sdkWithTokens(const <String>['tok']),
        httpClient: harness.http,
        clock: harness.clock,
        storage: store,
        pollingPolicy: PollingPolicy(jitter: 0),
        deviceIpResolver: () async => '198.51.100.7',
      );
      harness.http
        ..enqueue(jsonResponse(200, offering(<Object?>['paynow'])))
        ..enqueue(jsonResponse(200, offering(<Object?>['paynow'])))
        ..enqueue(
          jsonResponse(
            200,
            intentJson(
              status: 'REQUIRES_CUSTOMER_ACTION',
              nextAction: qrNextActionExpiringIn(10),
            ),
          ),
        );
      for (var i = 0; i < 50; i++) {
        harness.http.enqueue(
          jsonResponse(200, intentJson(status: 'SUCCEEDED')),
        );
      }
      await pumpEmbeddedSheet(
        tester,
        harness,
        payments: payments,
        presentation: const UqpaySheetPresentation.singleWallet('paynow'),
      );
      await pumpUntilIdle(tester, frames: 20);
      expect(find.text(l10n.cancel), findsOneWidget);

      // The poll sees SUCCEEDED; releasing the idempotency pin is held, so
      // the flow is done but its result has not reached the sheet.
      store.gate = Completer<void>();
      for (var i = 0; i < 30 && !payments.flows.single.isDone; i++) {
        harness.clock.advance(const Duration(seconds: 1));
        await pumpUntilIdle(tester, frames: 2);
      }
      expect(payments.flows.single.isDone, isTrue);
      expect(find.text(l10n.cancel), findsOneWidget);

      await tester.tap(find.text(l10n.cancel));
      await pumpUntilIdle(tester);
      store.gate!.complete();
      await pumpUntilIdle(tester);

      expect(harness.results, hasLength(1));
      expect(harness.results.single, isA<UqpayPaymentCompleted>());
    });
  });

  group('embedded sheets', () {
    testWidgets('a new intentId retires the old payment (its result goes to '
        'the old callback) and loads the new intent', (tester) async {
      final harness = SheetHarness();
      final first = <UqpayPaymentResult>[];
      final second = <UqpayPaymentResult>[];
      harness.http
        ..enqueue(jsonResponse(200, offering(<Object?>['card'], id: 'pi_A')))
        ..enqueue(jsonResponse(200, offering(<Object?>['card'], id: 'pi_B')));

      Widget host(String intentId, ValueChanged<UqpayPaymentResult> onResult) =>
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: UqpayPaymentSheet(
                  payments: harness.payments,
                  intentId: intentId,
                  returnUrl: kReturnUrl,
                  clock: harness.clock,
                  isWebPlatform: false,
                  onResult: onResult,
                ),
              ),
            ),
          );

      await tester.pumpWidget(host('pi_A', first.add));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host('pi_B', second.add));
      await tester.pumpAndSettle();

      expect(first, hasLength(1));
      expect(first.single, isA<UqpayPaymentCanceled>());
      expect(first.single.intentId, 'pi_A');
      expect(second, isEmpty);
      expect(harness.reads.map((r) => r.url.path).last, contains('pi_B'));
    });

    testWidgets('present() for an intent an embedded sheet holds returns '
        'Failed(invalidConfiguration) without opening a second sheet', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      Future<UqpayPaymentResult>? presented;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ElevatedButton(
                    key: const ValueKey<String>('open'),
                    onPressed: () => presented = UqpayPaymentSheet.present(
                      context,
                      payments: harness.payments,
                      intentId: kIntentId,
                      returnUrl: kReturnUrl,
                      clock: harness.clock,
                      isWebPlatform: false,
                    ),
                    child: const Text('open'),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: UqpayPaymentSheet(
                        payments: harness.payments,
                        intentId: kIntentId,
                        returnUrl: kReturnUrl,
                        clock: harness.clock,
                        isWebPlatform: false,
                        onResult: harness.results.add,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await pumpUntilIdle(tester, frames: 30);

      final result = await presented!;
      expect(result, isA<UqpayPaymentFailed>());
      expect(
        (result as UqpayPaymentFailed).error.code,
        UqpayErrorCode.invalidConfiguration,
      );
      expect(find.byType(UqpayPaymentSheet), findsOneWidget);
      expect(harness.reads, hasLength(1));
    });

    testWidgets('a second embedded sheet for the same intent is rejected '
        'and never loads', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      final second = <UqpayPaymentResult>[];
      Widget sheet(ValueChanged<UqpayPaymentResult> onResult) =>
          UqpayPaymentSheet(
            payments: harness.payments,
            intentId: kIntentId,
            returnUrl: kReturnUrl,
            clock: harness.clock,
            isWebPlatform: false,
            onResult: onResult,
          );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [sheet(harness.results.add), sheet(second.add)],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(harness.results, isEmpty);
      expect(second, hasLength(1));
      expect(
        (second.single as UqpayPaymentFailed).error.code,
        UqpayErrorCode.invalidConfiguration,
      );
      expect(harness.reads, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing an embedded sheet releases the intent', (
      tester,
    ) async {
      final harness = SheetHarness();
      harness.http
        ..enqueue(jsonResponse(200, offering(<Object?>['card'])))
        ..enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      await pumpEmbeddedSheet(tester, harness);
      await tester.pumpAndSettle();

      expect(harness.reads, hasLength(2));
      expect(harness.results, hasLength(1));
      expect(harness.results.single, isA<UqpayPaymentCanceled>());
      expect(find.byKey(const ValueKey<String>('uqpay-method-card')), findsOne);
    });
  });

  group('hosts without MaterialLocalizations', () {
    testWidgets('present() fails fast with a StateError, pushes nothing and '
        'does not lock the intent', (tester) async {
      final harness = SheetHarness();
      late BuildContext hostContext;
      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      Future<UqpayPaymentResult> open() => UqpayPaymentSheet.present(
        hostContext,
        payments: harness.payments,
        intentId: kIntentId,
        returnUrl: kReturnUrl,
        clock: harness.clock,
        isWebPlatform: false,
      );

      await expectLater(open(), throwsStateError);
      await tester.pump();
      expect(find.byType(UqpayPaymentSheet), findsNothing);
      expect(harness.http.requests, isEmpty);
      // Still a StateError, not "already open": the second-present guard
      // was never taken.
      await expectLater(
        open(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('MaterialLocalizations'),
          ),
        ),
      );
    });

    testWidgets('the embedded sheet works inside a CupertinoApp, card form '
        'included', (tester) async {
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: SingleChildScrollView(
              child: UqpayPaymentSheet(
                payments: harness.payments,
                intentId: kIntentId,
                returnUrl: kReturnUrl,
                clock: harness.clock,
                isWebPlatform: false,
                onResult: harness.results.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNWidgets(9));
      await tester.enterText(
        find.byKey(const ValueKey<String>('uqpay-card-number')),
        testPan,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('blank localisation overrides fall back', () {
    test('every control label has a non-blank fallback', () {
      const blank = _BlankLabels();
      expect(blank.closeLabel, l10n.close);
      expect(blank.doneLabel, l10n.done);
      expect(blank.payAmountLabel(r'$1.00'), l10n.payAmount(r'$1.00'));
      expect(blank.paySheetTitleLabel, l10n.paySheetTitle);
      expect(blank.testModeBannerSemanticsLabel, l10n.testModeBannerSemantics);
      // A real override is kept.
      expect(const _Renamed().closeLabel, 'Schliessen');
    });

    testWidgets('close button, pay button and sandbox banner stay labelled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = SheetHarness();
      harness.http.enqueue(jsonResponse(200, offering(<Object?>['card'])));
      await pumpEmbeddedSheet(
        tester,
        harness,
        localizations: const _BlankLabels(),
      );
      await tester.pumpAndSettle();

      final close = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('uqpay-close-button')),
      );
      expect(close.tooltip, l10n.close);
      expect(
        find.bySemanticsLabel(l10n.testModeBannerSemantics),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('uqpay-method-card')));
      await tester.pump();
      final payText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('uqpay-pay-button')),
          matching: find.byType(Text),
        ),
      );
      expect(payText.data, startsWith('Pay '));
      handle.dispose();
    });
  });

  group('appearance merges instead of replacing', () {
    final host = ThemeData(colorSchemeSeed: Colors.indigo);

    test('a partial text theme keeps the host sizes and colours', () {
      final theme = const UqpayAppearance(
        textTheme: TextTheme(
          titleMedium: TextStyle(fontWeight: FontWeight.bold),
        ),
      ).themeFor(host);
      expect(theme.textTheme.titleMedium!.fontWeight, FontWeight.bold);
      expect(
        theme.textTheme.titleMedium!.fontSize,
        host.textTheme.titleMedium!.fontSize,
      );
      expect(
        theme.textTheme.titleMedium!.color,
        host.textTheme.titleMedium!.color,
      );
      expect(theme.textTheme.headlineSmall, host.textTheme.headlineSmall);
    });

    test('payButtonStyle keeps the cornerRadius shape it does not set', () {
      final theme = UqpayAppearance(
        cornerRadius: 4,
        payButtonStyle: FilledButton.styleFrom(backgroundColor: Colors.teal),
      ).themeFor(host);
      final style = theme.filledButtonTheme.style!;
      expect(
        style.shape!.resolve(<WidgetState>{}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      expect(style.backgroundColor!.resolve(<WidgetState>{}), Colors.teal);
    });

    test('a shape in payButtonStyle wins over cornerRadius', () {
      final theme = UqpayAppearance(
        cornerRadius: 4,
        payButtonStyle: FilledButton.styleFrom(shape: const StadiumBorder()),
      ).themeFor(host);
      expect(
        theme.filledButtonTheme.style!.shape!.resolve(<WidgetState>{}),
        const StadiumBorder(),
      );
    });
  });
}

/// A pin store whose `remove` can be held, to widen the window between a
/// flow being done and its result being delivered.
class _GatedRemoveStore extends InMemoryKeyValueStore {
  Completer<void>? gate;

  @override
  Future<void> remove(String key) async {
    final held = gate;
    if (held != null) {
      await held.future;
    }
    return super.remove(key);
  }
}

/// A merchant override that blanks every control label.
class _BlankLabels extends UqpayLocalizations {
  const _BlankLabels();

  @override
  String get close => '';

  @override
  String get done => ' ';

  @override
  String payAmount(String amount) => '';

  @override
  String get paySheetTitle => '';

  @override
  String get testModeBannerSemantics => '';
}

class _Renamed extends UqpayLocalizations {
  const _Renamed();

  @override
  String get close => 'Schliessen';
}
