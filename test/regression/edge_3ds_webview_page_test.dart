import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/webview_challenge_presenter_io.dart'
    show challengeExternalLauncher;
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart' show NavigationDecision;

import '../support/fakes.dart';
import '../three_ds/support/fake_webview_platform.dart';

/// 3DS page-side regressions — the REAL
/// challenge webview body, driven through a fake `WebViewPlatform`.
void main() {
  late FakeWebViewPlatform platform;
  late ManualClock clock;
  late List<Uri> launched;
  late Future<bool> Function(Uri) originalLauncher;
  var launchResult = true;
  Error? launchThrows;

  setUp(() {
    platform = FakeWebViewPlatform.install();
    clock = ManualClock();
    launched = <Uri>[];
    launchResult = true;
    launchThrows = null;
    originalLauncher = challengeExternalLauncher;
    challengeExternalLauncher = (uri) async {
      launched.add(uri);
      final failure = launchThrows;
      if (failure != null) {
        throw failure;
      }
      return launchResult;
    };
  });

  tearDown(() {
    challengeExternalLauncher = originalLauncher;
  });

  UqpayChallengeRequest request({
    String returnUrl = 'https://shop.example/checkout/return',
    Duration timeout = const Duration(seconds: 10),
    Future<void>? cancelled,
  }) => UqpayChallengeRequest(
    intentId: 'pi_123',
    action: const UqpayNextAction(
      rawType: 'redirect_to_url',
      redirectToUrl: UqpayRedirectToUrl(url: 'https://acs.example/challenge'),
    ),
    returnUrl: Uri.parse(returnUrl),
    timeout: timeout,
    cancelled: cancelled,
  );

  /// Pumps an app, presents [req] through the SDK presenter and returns the
  /// list the single outcome lands in.
  Future<List<UqpayChallengeOutcome>> open(
    WidgetTester tester,
    UqpayChallengeRequest req, {
    GlobalKey<NavigatorState>? key,
  }) async {
    final navigatorKey = key ?? GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
    );
    final outcomes = <UqpayChallengeOutcome>[];
    unawaited(
      UqpayWebviewChallengePresenter(
        navigator: () => navigatorKey.currentState!,
        clock: clock,
      ).present(req).then(outcomes.add),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UqpayChallengePage), findsOneWidget);
    expect(platform.last.loadedRequests, [
      Uri.parse('https://acs.example/challenge'),
    ]);
    return outcomes;
  }

  Finder page() => find.byType(UqpayChallengePage);

  group('non-web links are handed to the OS and keep the challenge', () {
    for (final url in <String>[
      'tel:+6560000000',
      'mailto:support@bank.example',
      'sms:+6560000000',
      'intent://approve#Intent;scheme=bankapp;package=com.bank;end',
      'bankapp://approve?tx=1',
      'itms-apps://apps.apple.com/app/id1',
    ]) {
      testWidgets(url.split(':').first, (tester) async {
        final outcomes = await open(tester, request());

        final decision = await platform.last.navigate(url);
        await tester.pumpAndSettle();

        expect(decision, NavigationDecision.prevent);
        expect(launched, [Uri.parse(url)]);
        expect(outcomes, isEmpty, reason: 'never ends the challenge');
        expect(page(), findsOneWidget);
      });
    }

    testWidgets('a refused or throwing launch leaves the page open, with no '
        'uncaught error', (tester) async {
      final outcomes = await open(tester, request());
      launchResult = false;
      expect(
        await platform.last.navigate('bankapp://approve'),
        NavigationDecision.prevent,
      );
      launchThrows = StateError('no activity');
      expect(
        await platform.last.navigate('bankapp://approve'),
        NavigationDecision.prevent,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(launched, hasLength(2));
      expect(outcomes, isEmpty);
      expect(page(), findsOneWidget);
    });

    testWidgets('file:, content: and javascript: are blocked, never launched '
        'and never end the challenge', (tester) async {
      final outcomes = await open(tester, request());
      for (final url in <String>[
        'file:///data/data/app/secret',
        'content://com.app.provider/x',
        'javascript:alert(1)',
      ]) {
        expect(await platform.last.navigate(url), NavigationDecision.prevent);
      }
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
      expect(outcomes, isEmpty);
      expect(page(), findsOneWidget);
    });

    testWidgets('ordinary https ACS navigations keep loading', (tester) async {
      final outcomes = await open(tester, request());
      expect(
        await platform.last.navigate('https://acs.example/step-2?x=1'),
        NavigationDecision.navigate,
      );
      expect(outcomes, isEmpty);
    });
  });

  group('the challenge ends only on a main-frame return', () {
    testWidgets('main-frame return URL -> returned(uri), page closes', (
      tester,
    ) async {
      final outcomes = await open(tester, request());
      const url = 'https://shop.example/checkout/return?status=whatever';

      expect(await platform.last.navigate(url), NavigationDecision.prevent);
      await tester.pumpAndSettle();

      expect(outcomes, hasLength(1));
      expect(
        (outcomes.single as UqpayChallengeReturned).returnUri,
        Uri.parse(url),
      );
      expect(page(), findsNothing);
    });

    testWidgets('a sub-frame navigation to the return URL is ignored', (
      tester,
    ) async {
      final outcomes = await open(tester, request());

      expect(
        await platform.last.navigate(
          'https://shop.example/checkout/return?x=1',
          isMainFrame: false,
        ),
        NavigationDecision.navigate,
      );
      expect(
        await platform.last.navigate(
          'bankapp://probe',
          isMainFrame: false,
        ),
        NavigationDecision.prevent,
        reason: 'an app-probe iframe neither ends the step nor opens an app',
      );
      await tester.pumpAndSettle();

      expect(outcomes, isEmpty);
      expect(launched, isEmpty);
      expect(page(), findsOneWidget);
    });

    testWidgets("the return URL's custom app scheme ends the step; another "
        'app scheme is launched', (tester) async {
      final outcomes = await open(
        tester,
        request(returnUrl: 'myapp://payment'),
      );

      expect(
        await platform.last.navigate('bankapp://approve'),
        NavigationDecision.prevent,
      );
      await tester.pumpAndSettle();
      expect(outcomes, isEmpty);
      expect(launched, [Uri.parse('bankapp://approve')]);

      expect(
        await platform.last.navigate('MyApp://payment/done?ok=1'),
        NavigationDecision.prevent,
      );
      await tester.pumpAndSettle();
      expect(outcomes.single, isA<UqpayChallengeReturned>());
      expect(page(), findsNothing);
    });

    testWidgets('sentinel return URL keeps the old rule: a non-web scheme '
        'ends the step; tel: is launched', (tester) async {
      final outcomes = await open(
        tester,
        request(returnUrl: 'uqpay-return://none'),
      );
      await platform.last.navigate('tel:+6560000000');
      await tester.pumpAndSettle();
      expect(outcomes, isEmpty);
      expect(launched, [Uri.parse('tel:+6560000000')]);

      await platform.last.navigate('merchantapp://back');
      await tester.pumpAndSettle();
      expect(outcomes.single, isA<UqpayChallengeReturned>());
    });

    testWidgets('a main-frame load error -> failed(networkError)', (
      tester,
    ) async {
      final outcomes = await open(tester, request());
      platform.last.error(isForMainFrame: false);
      await tester.pumpAndSettle();
      expect(outcomes, isEmpty);
      platform.last.error(isForMainFrame: true);
      await tester.pumpAndSettle();
      final failed = outcomes.single as UqpayChallengeFailed;
      expect(failed.error.code, UqpayErrorCode.networkError);
      expect(failed.error.isOutcomeUnknown, isTrue);
    });
  });

  group('only a real background trip re-arms the deadline', () {
    void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
      states.forEach(tester.binding.handleAppLifecycleStateChanged);
    }

    testWidgets('inactive -> resumed toggles never extend the window', (
      tester,
    ) async {
      final outcomes = await open(tester, request());
      // 30 x (9 s, Control Center blip): the old code re-armed every time.
      for (var i = 0; i < 30 && outcomes.isEmpty; i++) {
        clock.advance(const Duration(seconds: 9));
        lifecycle(tester, [
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]);
        await tester.pumpAndSettle();
      }
      expect(outcomes.single, isA<UqpayChallengeTimedOut>());
      expect(
        clock.elapsed,
        lessThanOrEqualTo(const Duration(seconds: 18)),
        reason: 'timed out on the original 10 s window',
      );
      expect(page(), findsNothing);
    });

    testWidgets('paused -> resumed re-arms in full; background time is free', (
      tester,
    ) async {
      final outcomes = await open(tester, request());
      clock.advance(const Duration(seconds: 9));
      lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      clock.advance(const Duration(hours: 1));
      await tester.pumpAndSettle();
      expect(outcomes, isEmpty, reason: 'no deadline runs in the background');

      lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();
      clock.advance(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(outcomes, isEmpty, reason: 'a fresh full window after resume');

      clock.advance(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(outcomes.single, isA<UqpayChallengeTimedOut>());
      expect(clock.pendingTimers, 0, reason: 'no timer outlives the page');
    });
  });

  group('hygiene on every exit, never the app-global cookie jar', () {
    void expectScrubbed() {
      expect(platform.last.clearCacheCalls, 1);
      expect(platform.last.clearLocalStorageCalls, 1);
      expect(
        platform.cookieManagersCreated,
        0,
        reason: "the host app's own webview cookies must survive",
      );
    }

    testWidgets('return', (tester) async {
      await open(tester, request());
      await platform.last.navigate('https://shop.example/checkout/return');
      await tester.pumpAndSettle();
      expectScrubbed();
    });

    testWidgets('close button', (tester) async {
      final outcomes = await open(tester, request());
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(outcomes.single, isA<UqpayChallengeDismissed>());
      expectScrubbed();
    });

    testWidgets('system back', (tester) async {
      final outcomes = await open(tester, request());
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(outcomes.single, isA<UqpayChallengeDismissed>());
      expectScrubbed();
    });

    testWidgets('timeout', (tester) async {
      await open(tester, request());
      clock.advance(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expectScrubbed();
    });

    testWidgets('a throwing clearCache / failing clearLocalStorage never '
        'breaks the teardown or loses the outcome', (tester) async {
      platform.hygieneThrows = StateError('webview already gone');
      final outcomes = await open(tester, request());
      await platform.last.navigate('https://shop.example/checkout/return');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(outcomes.single, isA<UqpayChallengeReturned>());
      expect(page(), findsNothing);
      expectScrubbed();
    });
  });

  group('the cancellation signal closes the page', () {
    testWidgets('completing request.cancelled pops the page as dismissed', (
      tester,
    ) async {
      final cancel = Completer<void>();
      final outcomes = await open(tester, request(cancelled: cancel.future));

      cancel.complete();
      await tester.pumpAndSettle();

      expect(outcomes.single, isA<UqpayChallengeDismissed>());
      expect(page(), findsNothing);
      expect(platform.last.clearCacheCalls, 1);
      expect(clock.pendingTimers, 0);
    });

    testWidgets('with a dialog on top, only the challenge route is removed', (
      tester,
    ) async {
      final key = GlobalKey<NavigatorState>();
      final cancel = Completer<void>();
      final outcomes = await open(
        tester,
        request(cancelled: cancel.future),
        key: key,
      );
      unawaited(
        showDialog<void>(
          context: key.currentContext!,
          builder: (_) => const AlertDialog(content: Text('merchant dialog')),
        ),
      );
      await tester.pumpAndSettle();

      cancel.complete();
      await tester.pumpAndSettle();

      expect(outcomes.single, isA<UqpayChallengeDismissed>());
      expect(page(), findsNothing);
      expect(find.text('merchant dialog'), findsOneWidget);
    });

    testWidgets('a cancellation after the page already finished is inert', (
      tester,
    ) async {
      final cancel = Completer<void>();
      final outcomes = await open(tester, request(cancelled: cancel.future));
      await platform.last.navigate('https://shop.example/checkout/return');
      await tester.pumpAndSettle();
      cancel.complete();
      await tester.pumpAndSettle();
      expect(outcomes.single, isA<UqpayChallengeReturned>());
      expect(tester.takeException(), isNull);
    });
  });
}
