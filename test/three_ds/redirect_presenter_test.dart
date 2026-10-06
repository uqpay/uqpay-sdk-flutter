import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';

/// The web presenter: full-page redirect via `_self`, with
/// the in-flight intent id persisted BEFORE navigating away (so a reload can
/// recover it) and nothing sensitive anywhere near the URL.
void main() {
  late InMemoryKeyValueStore store;
  late List<Uri> launched;

  setUp(() {
    store = InMemoryKeyValueStore();
    launched = <Uri>[];
  });

  UqpayChallengeRequest request({
    String? url = 'https://acs.example/challenge',
  }) => UqpayChallengeRequest(
    intentId: 'pi_123',
    action: UqpayNextAction(
      rawType: 'redirect_to_url',
      redirectToUrl: UqpayRedirectToUrl(
        url: url,
        returnUrl: 'https://shop.example/return',
      ),
    ),
    returnUrl: Uri.parse('https://shop.example/return'),
  );

  UqpayRedirectChallengePresenter presenter({bool launchResult = true}) =>
      UqpayRedirectChallengePresenter(
        store: store,
        launch: (url) async {
          launched.add(url);
          return launchResult;
        },
      );

  test('persists the intent id BEFORE launching, then redirects', () async {
    var storedWhenLaunched = '';
    final p = UqpayRedirectChallengePresenter(
      store: store,
      launch: (url) async {
        launched.add(url);
        storedWhenLaunched =
            await store.read(
              UqpayRedirectChallengePresenter.pendingIntentKey,
            ) ??
            '';
        return true;
      },
    );

    UqpayChallengeOutcome? outcome;
    unawaited(p.present(request()).then((o) => outcome = o));
    await pumpEventQueue();

    expect(launched, [Uri.parse('https://acs.example/challenge')]);
    expect(storedWhenLaunched, 'pi_123', reason: 'written before navigation');
    // Off the web (this test VM) the external browser is out of sight, so
    // the presenter reports the hand-off as ended at once and the flow
    // polls the server; on the web the page unloads and the future is
    // never observed to complete.
    expect(
      outcome,
      isA<UqpayChallengeDismissed>(),
    );
  });

  test('a refused launch -> failed, and the pending slot is cleared', () async {
    final outcome = await presenter(launchResult: false).present(request());

    expect(outcome, isA<UqpayChallengeFailed>());
    expect(
      (outcome as UqpayChallengeFailed).error.code,
      UqpayErrorCode.invalidConfiguration,
    );
    expect(store.entries, isEmpty);
  });

  test('a throwing launcher -> failed, never a throw', () async {
    final p = UqpayRedirectChallengePresenter(
      store: store,
      launch: (_) async => throw StateError('boom'),
    );
    final outcome = await p.present(request());
    expect(outcome, isA<UqpayChallengeFailed>());
  });

  test('a non-redirect action -> failed(invalidConfiguration): an iframe '
      'POST form cannot become a GET redirect', () async {
    final outcome = await presenter().present(
      UqpayChallengeRequest(
        intentId: 'pi_123',
        action: const UqpayNextAction(
          rawType: 'redirect_iframe',
          redirectIframe: UqpayRedirectIframe(iframe: '<form></form>'),
        ),
        returnUrl: Uri.parse('https://shop.example/return'),
      ),
    );

    expect(outcome, isA<UqpayChallengeFailed>());
    expect(launched, isEmpty);
    expect(store.entries, isEmpty, reason: 'nothing persisted for a refusal');
  });

  test('a missing or non-http challenge URL -> failed', () async {
    expect(
      await presenter().present(request(url: null)),
      isA<UqpayChallengeFailed>(),
    );
    expect(
      await presenter().present(request(url: 'javascript:alert(1)')),
      isA<UqpayChallengeFailed>(),
    );
    expect(launched, isEmpty);
  });

  test(
    'nothing sensitive is persisted — only the opaque intent id',
    () async {
      unawaited(presenter().present(request()));
      await pumpEventQueue();
      expect(store.entries, {
        UqpayRedirectChallengePresenter.pendingIntentKey: 'pi_123',
      });
    },
  );
}
