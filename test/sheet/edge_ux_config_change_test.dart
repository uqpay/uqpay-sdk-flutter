import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

import '../support/fakes.dart';
import 'support/sheet_harness.dart';

/// The sheet survives a configuration change mid-flow — dark-mode
/// toggle, font-size change, language change and a window resize
/// (rotation / split screen) — with no state loss and no duplicate request.
void main() {
  const l10n = UqpayLocalizations();

  testWidgets('theme light -> dark mid-form keeps typed values and sends one '
      'confirm', (tester) async {
    final h = await _Host.pump(tester);
    await h.openCardForm(tester);
    await _fillFirstHalf(tester);

    h.update((c) => c.copyWith(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      Theme.of(tester.element(find.byKey(_k('uqpay-pay-button')))).brightness,
      Brightness.dark,
      reason: 'the sheet follows the host ThemeMode live',
    );
    _expectFirstHalfKept(tester);
    await h.finishAndPay(tester);
  });

  testWidgets('text scale 1.0 -> 2.0 mid-form keeps typed values and sends '
      'one confirm', (tester) async {
    final h = await _Host.pump(tester);
    await h.openCardForm(tester);
    await _fillFirstHalf(tester);

    h.update((c) => c.copyWith(textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byKey(_k('uqpay-card-number'))),
      ),
      const TextScaler.linear(2),
    );
    _expectFirstHalfKept(tester);
    await h.finishAndPay(tester);
  });

  testWidgets('locale en -> de mid-form re-localises the sheet, keeps typed '
      'values and sends one confirm', (tester) async {
    final h = await _Host.pump(tester);
    await h.openCardForm(tester);
    expect(find.text(l10n.cardDetailsTitle), findsOneWidget);
    await _fillFirstHalf(tester);

    h.update((c) => c.copyWith(locale: const Locale('de')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(_GermanStrings.cardTitle), findsOneWidget);
    expect(find.text(l10n.cardDetailsTitle), findsNothing);
    _expectFirstHalfKept(tester);
    await h.finishAndPay(tester);
    // The risk snapshot is taken at pay time, in the language now shown.
    expect(h.harness.confirms.single.body, contains('"language":"de"'));
  });

  for (final resize in <(String, Size)>[
    ('rotation to landscape', const Size(800, 400)),
    ('split screen (narrow half)', const Size(360, 600)),
  ]) {
    testWidgets('window resize mid-form — ${resize.$1} — keeps typed values '
        'and sends one confirm', (tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(400, 800);
      addTearDown(tester.view.reset);
      final h = await _Host.pump(tester);
      await h.openCardForm(tester);
      await _fillFirstHalf(tester);

      tester.view.physicalSize = resize.$2;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        MediaQuery.sizeOf(tester.element(find.byKey(_k('uqpay-card-number')))),
        resize.$2,
      );
      _expectFirstHalfKept(tester);
      await h.finishAndPay(tester);
    });
  }

  testWidgets('every change at once, then back again, still sends exactly '
      'one confirm', (tester) async {
    final h = await _Host.pump(tester);
    await h.openCardForm(tester);
    await _fillFirstHalf(tester);

    h.update(
      (c) => c.copyWith(
        themeMode: ThemeMode.dark,
        textScale: 2,
        locale: const Locale('de'),
      ),
    );
    tester.view.physicalSize = const Size(1800, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    h.update((c) => const _HostConfig());
    tester.view.resetPhysicalSize();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    _expectFirstHalfKept(tester);
    await h.finishAndPay(tester);
    expect(h.harness.reads, hasLength(2), reason: 'load + confirm guard only');
  });

  group('while the confirm is in flight (processing)', () {
    testWidgets('embedded: theme, scale, locale and size changes neither '
        'resend the confirm nor deliver the result twice', (tester) async {
      final h = await _Host.pump(tester);
      await h.openCardForm(tester);
      await _fillFirstHalf(tester);
      await _fillSecondHalf(tester);
      final confirm = h.holdConfirm();
      await tapPay(tester);
      await pumpUntilIdle(tester);
      expect(find.text(l10n.processingTitle), findsOneWidget);
      expect(h.harness.confirms, hasLength(1));

      await _churnConfiguration(tester, h);

      expect(tester.takeException(), isNull);
      expect(h.harness.confirms, hasLength(1));
      expect(find.text(l10n.processingTitle), findsOneWidget);
      expect(h.harness.results, isEmpty);

      confirm.complete(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.successTitle), findsOneWidget);
      await tester.ensureVisible(find.text(l10n.done));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.done));
      await tester.pumpAndSettle();
      // A late configuration change after the result changes nothing.
      h.update((c) => c.copyWith(themeMode: ThemeMode.light));
      await tester.pumpAndSettle();

      expect(h.harness.confirms, hasLength(1));
      expect(h.harness.results, hasLength(1));
      expect(h.harness.results.single, isA<UqpayPaymentCompleted>());
    });

    testWidgets('presented: the same churn while processing resolves the '
        'present() future exactly once', (tester) async {
      final h = await _Host.pump(tester, presented: true);
      await tester.tap(find.byKey(_k('open-sheet')));
      await tester.pumpAndSettle();
      await h.openCardForm(tester);
      await _fillFirstHalf(tester);

      // Mid-form: dark mode reaches the presented sheet too.
      h.update((c) => c.copyWith(themeMode: ThemeMode.dark));
      await tester.pumpAndSettle();
      expect(
        Theme.of(
          tester.element(find.byKey(_k('uqpay-pay-button'))),
        ).brightness,
        Brightness.dark,
      );
      _expectFirstHalfKept(tester);

      await _fillSecondHalf(tester);
      final confirm = h.holdConfirm();
      await tapPay(tester);
      await pumpUntilIdle(tester);
      expect(find.text(l10n.processingTitle), findsOneWidget);

      await _churnConfiguration(tester, h);
      expect(tester.takeException(), isNull);
      expect(find.text(l10n.processingTitle), findsOneWidget);
      expect(h.harness.results, isEmpty);

      confirm.complete(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(l10n.done));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.done));
      await tester.pumpAndSettle();

      expect(h.harness.confirms, hasLength(1));
      expect(h.harness.results, hasLength(1));
      expect(h.harness.results.single, isA<UqpayPaymentCompleted>());
      expect(find.byType(UqpayPaymentSheet), findsNothing);
    });
  });
}

ValueKey<String> _k(String value) => ValueKey<String>(value);

String _textOf(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(find.byKey(_k(key))).controller!.text;

/// Card number, expiry, CVC and name: the half typed before the change.
Future<void> _fillFirstHalf(WidgetTester tester) async {
  await tester.enterText(find.byKey(_k('uqpay-card-number')), testPan);
  await tester.enterText(find.byKey(_k('uqpay-card-expiry')), '12/30');
  await tester.enterText(find.byKey(_k('uqpay-card-cvc')), testCvc);
  await tester.enterText(find.byKey(_k('uqpay-card-name')), 'Ada Lovelace');
  await tester.pump();
}

void _expectFirstHalfKept(WidgetTester tester) {
  expect(_textOf(tester, 'uqpay-card-number'), '4242 4242 4242 4242');
  expect(_textOf(tester, 'uqpay-card-expiry'), '12/30');
  expect(_textOf(tester, 'uqpay-card-cvc'), testCvc);
  expect(_textOf(tester, 'uqpay-card-name'), 'Ada Lovelace');
}

/// Email and billing address: typed after the change.
Future<void> _fillSecondHalf(WidgetTester tester) async {
  await tester.enterText(find.byKey(_k('uqpay-card-email')), 'ada@example.com');
  await tester.enterText(
    find.byKey(_k('uqpay-card-street')),
    '221B Baker Street',
  );
  await tester.enterText(find.byKey(_k('uqpay-card-city')), 'London');
  await tester.enterText(find.byKey(_k('uqpay-card-state')), 'Greater London');
  await tester.enterText(find.byKey(_k('uqpay-card-postcode')), 'NW1 6XE');
  await tester.pump();
}

/// Theme, text scale, locale and window size, one after another, with
/// frames between — the processing screen holds a spinner, so no
/// `pumpAndSettle`.
Future<void> _churnConfiguration(WidgetTester tester, _Host h) async {
  addTearDown(tester.view.reset);
  h.update((c) => c.copyWith(themeMode: ThemeMode.light));
  await pumpUntilIdle(tester);
  h.update((c) => c.copyWith(themeMode: ThemeMode.dark));
  await pumpUntilIdle(tester);
  h.update((c) => c.copyWith(textScale: 2));
  await pumpUntilIdle(tester);
  h.update((c) => c.copyWith(locale: const Locale('de')));
  await pumpUntilIdle(tester);
  tester.view.physicalSize = const Size(2400, 1200);
  await pumpUntilIdle(tester);
  tester.view.physicalSize = const Size(1080, 1800);
  await pumpUntilIdle(tester);
}

@immutable
class _HostConfig {
  const _HostConfig({
    this.themeMode = ThemeMode.light,
    this.textScale = 1,
    this.locale = const Locale('en'),
  });

  final ThemeMode themeMode;
  final double textScale;
  final Locale locale;

  _HostConfig copyWith({
    ThemeMode? themeMode,
    double? textScale,
    Locale? locale,
  }) => _HostConfig(
    themeMode: themeMode ?? this.themeMode,
    textScale: textScale ?? this.textScale,
    locale: locale ?? this.locale,
  );
}

/// A host app whose theme mode, text scale and locale can be changed while
/// the sheet is up, the way the OS changes them under a running app.
class _Host {
  _Host._(this.harness, this.config);

  final SheetHarness harness;
  final ValueNotifier<_HostConfig> config;

  void update(_HostConfig Function(_HostConfig) change) =>
      config.value = change(config.value);

  static Future<_Host> pump(
    WidgetTester tester, {
    bool presented = false,
  }) async {
    final harness = SheetHarness();
    harness.http.enqueue(jsonResponse(200, intentJson()));
    final config = ValueNotifier<_HostConfig>(const _HostConfig());
    addTearDown(config.dispose);
    final host = _Host._(harness, config);

    final Widget home = presented
        ? Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  key: _k('open-sheet'),
                  onPressed: () => unawaited(
                    UqpayPaymentSheet.present(
                      context,
                      payments: harness.payments,
                      intentId: kIntentId,
                      returnUrl: kReturnUrl,
                      clock: harness.clock,
                      isWebPlatform: false,
                    ).then(harness.results.add),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          )
        : Scaffold(
            body: SingleChildScrollView(
              child: UqpayPaymentSheet(
                payments: harness.payments,
                intentId: kIntentId,
                returnUrl: kReturnUrl,
                clock: harness.clock,
                isWebPlatform: false,
                onResult: harness.results.add,
              ),
            ),
          );

    await tester.pumpWidget(
      ValueListenableBuilder<_HostConfig>(
        valueListenable: config,
        builder: (context, c, _) => MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.indigo),
          darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo,
            brightness: Brightness.dark,
          ),
          themeMode: c.themeMode,
          locale: c.locale,
          supportedLocales: const <Locale>[Locale('en'), Locale('de')],
          localizationsDelegates: const <LocalizationsDelegate<Object?>>[
            _AnyLocaleMaterialDelegate(),
            _AnyLocaleCupertinoDelegate(),
            _GermanUqpayDelegate(),
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(c.textScale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return host;
  }

  Future<void> openCardForm(WidgetTester tester) async {
    await tester.tap(find.byKey(_k('uqpay-method-card')));
    await tester.pumpAndSettle();
  }

  /// Queues the confirm guard read and a confirm whose response the test
  /// releases, so the sheet sits on its processing screen.
  Completer<UqpayHttpResponse> holdConfirm() {
    final completer = Completer<UqpayHttpResponse>();
    harness.http
      ..enqueue(jsonResponse(200, intentJson()))
      ..enqueueHandler((_) => completer.future);
    return completer;
  }

  /// Types the rest of the form, pays, and checks exactly one confirm went
  /// out and exactly one result came back.
  Future<void> finishAndPay(WidgetTester tester) async {
    await _fillSecondHalf(tester);
    harness.http
      ..enqueue(jsonResponse(200, intentJson()))
      ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
    await tapPay(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(harness.confirms, hasLength(1));
    final body = harness.confirms.single.body!;
    expect(body, contains(testPan));
    expect(body, contains('"email":"ada@example.com"'));
    await tester.tap(find.byKey(_k('uqpay-close-button')));
    await tester.pumpAndSettle();
    expect(harness.results, hasLength(1));
    expect(harness.results.single, isA<UqpayPaymentCompleted>());
  }
}

/// A host that localises Material for German (as GlobalMaterialLocalizations
/// would); the English defaults stand in for the German strings.
class _AnyLocaleMaterialDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _AnyLocaleMaterialDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      DefaultMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_AnyLocaleMaterialDelegate old) => false;
}

class _AnyLocaleCupertinoDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _AnyLocaleCupertinoDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      DefaultCupertinoLocalizations.load(locale);

  @override
  bool shouldReload(_AnyLocaleCupertinoDelegate old) => false;
}

/// The merchant's German UqpayLocalizations, delivered through the normal
/// Localizations mechanism so a locale change swaps them live.
class _GermanUqpayDelegate extends LocalizationsDelegate<UqpayLocalizations> {
  const _GermanUqpayDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<UqpayLocalizations> load(Locale locale) =>
      SynchronousFuture<UqpayLocalizations>(
        locale.languageCode == 'de'
            ? const _GermanStrings()
            : const UqpayLocalizations(),
      );

  @override
  bool shouldReload(_GermanUqpayDelegate old) => false;
}

class _GermanStrings extends UqpayLocalizations {
  const _GermanStrings();

  static const String cardTitle = 'Kartendaten';

  @override
  String get cardDetailsTitle => cardTitle;
}
