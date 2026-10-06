import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';

import '../support/fakes.dart';

/// A store whose every call throws — `localStorage` blocked / SecurityError.
class _BrokenStore implements KeyValueStore {
  @override
  Future<String?> read(String key) => throw StateError('blocked');

  @override
  Future<void> write(String key, String value) => throw StateError('blocked');

  @override
  Future<void> remove(String key) => throw StateError('blocked');

  @override
  Future<Set<String>> keysWithPrefix(String prefix) =>
      throw StateError('blocked');
}

/// A payments facade whose reconcile throws (an SDK bug / plugin failure).
class _ThrowingPayments implements UqpayPayments {
  int calls = 0;

  @override
  Future<UqpayPaymentResult> reconcile(String intentId) async {
    calls++;
    throw StateError('blocked');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 3DS web-return regressions: the redirect presenter is https-only,
/// `UqpayReturnHandler.consume` never throws, and repeated query keys are
/// handled.
void main() {
  UqpayChallengeRequest request(String? url) => UqpayChallengeRequest(
    intentId: 'pi_123',
    action: UqpayNextAction(
      rawType: 'redirect_to_url',
      redirectToUrl: UqpayRedirectToUrl(url: url),
    ),
    returnUrl: Uri.parse('https://shop.example/return'),
  );

  group('the redirect presenter only ever opens https', () {
    for (final url in <String>[
      'http://acs.example/challenge',
      'HTTP://acs.example/challenge',
      'bankapp://challenge',
      'javascript:alert(1)',
      'data:text/html,<p>x</p>',
      'https:///no-host',
      '/relative/challenge',
    ]) {
      test(url, () async {
        final store = InMemoryKeyValueStore();
        final launched = <Uri>[];
        final outcome = await UqpayRedirectChallengePresenter(
          store: store,
          launch: (u) async {
            launched.add(u);
            return true;
          },
        ).present(request(url));

        expect(outcome, isA<UqpayChallengeFailed>());
        final error = (outcome as UqpayChallengeFailed).error;
        expect(error.code, UqpayErrorCode.invalidConfiguration);
        expect(error.developerMessage, contains('https'));
        expect(launched, isEmpty, reason: 'never navigates');
        expect(store.entries, isEmpty, reason: 'nothing persisted');
      });
    }

    test('https is still opened (and the slot written first)', () async {
      final store = InMemoryKeyValueStore();
      final launched = <Uri>[];
      final outcome = await UqpayRedirectChallengePresenter(
        store: store,
        launch: (u) async {
          launched.add(u);
          return true;
        },
      ).present(request('https://acs.example/challenge'));
      // Off the web, the external-browser hand-off reports dismissed and the
      // flow polls (the web-only "never completes until cancelled" branch
      // needs kIsWeb and cannot run on the VM).
      expect(outcome, isA<UqpayChallengeDismissed>());
      expect(launched, [Uri.parse('https://acs.example/challenge')]);
    });
  });

  group('consume never throws', () {
    late PaymentsHarness h;
    late InMemoryKeyValueStore store;
    late UqpayReturnHandler handler;

    setUp(() {
      h = PaymentsHarness();
      store = InMemoryKeyValueStore();
      handler = UqpayReturnHandler(payments: h.payments, store: store);
    });

    test('a blank slot counts as no slot (and is cleared)', () async {
      await store.write(UqpayRedirectChallengePresenter.pendingIntentKey, '  ');
      final result = await handler.consume(
        Uri.parse('https://shop.example/return'),
      );
      expect(result, isNull);
      expect(h.http.requests, isEmpty);
      expect(store.entries, isEmpty);
    });

    test('a blank slot falls through to the URL parameter', () async {
      await store.write(
        UqpayRedirectChallengePresenter.pendingIntentKey,
        ' \t',
      );
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final result = await handler.consume(
        Uri.parse('https://shop.example/return?uqpay_intent=pi_123'),
      );
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test('a padded slot is trimmed before use', () async {
      await store.write(
        UqpayRedirectChallengePresenter.pendingIntentKey,
        ' pi_123 ',
      );
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      await handler.consume(Uri.parse('https://shop.example/return'));
      expect(h.reads.single.url.path, endsWith('/pi_123'));
    });

    test('malformed percent-encoding in the URL -> null, no throw', () async {
      final result = await handler.consume(
        Uri.parse('https://shop.example/return?uqpay_intent=%E0%A4%A'),
      );
      expect(result, isNull);
    });

    test('a store that throws on everything: the URL parameter still '
        'resolves from the server', () async {
      final payments = UqpayPayments.withDependencies(
        sdk: sdkWithTokens(const <String>['tok']),
        httpClient: h.http,
        clock: FakeClock(),
        storage: _BrokenStore(),
        pollingPolicy: PollingPolicy(jitter: 0),
      );
      h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));
      final broken = UqpayReturnHandler(
        payments: payments,
        store: _BrokenStore(),
      );

      final result = await broken.consume(
        Uri.parse('https://shop.example/return?uqpay_intent=pi_123'),
      );

      // Pin release over a blocked store no longer
      // escapes; the server's SUCCEEDED is reported.
      expect(result, isA<UqpayPaymentCompleted>());
    });

    test('a reconcile that throws becomes Pending with a cause; its '
        'reconcile() retries', () async {
      final payments = _ThrowingPayments();
      final result = await UqpayReturnHandler(
        payments: payments,
        store: InMemoryKeyValueStore(),
      ).consume(Uri.parse('https://shop.example/return?uqpay_intent=pi_123'));

      expect(result, isA<UqpayPaymentPending>());
      final pending = result! as UqpayPaymentPending;
      expect(pending.intentId, 'pi_123');
      expect(pending.cause?.isOutcomeUnknown, isTrue);
      expect(
        pending.cause?.developerMessage,
        isNot(contains('blocked')),
        reason: 'exception text is never echoed',
      );
      await expectLater(pending.reconcile(), throwsStateError);
      expect(payments.calls, 2, reason: 'reconcile() retries the read');
    });
  });

  group('repeated query keys', () {
    String? id(String url) =>
        UqpayReturnHandler.intentIdFromUri(Uri.parse(url));

    test('a blank duplicate cannot mask the intent id, in either order', () {
      expect(id('https://s/r?uqpay_intent=pi_1&uqpay_intent='), 'pi_1');
      expect(id('https://s/r?uqpay_intent=&uqpay_intent=pi_1'), 'pi_1');
      expect(id('https://s/r?uqpay_intent=pi_1&uqpay_intent=pi_1'), 'pi_1');
      expect(id('https://s/#/r?uqpay_intent=&uqpay_intent=pi_1'), 'pi_1');
    });

    test('two different ids are ambiguous -> null', () {
      expect(id('https://s/r?uqpay_intent=pi_1&uqpay_intent=pi_2'), isNull);
    });

    test('returnUrlFor keeps repeated keys and replaces uqpay_intent', () {
      final built = UqpayReturnHandler.returnUrlFor(
        Uri.parse('https://s/r?a=1&a=2&uqpay_intent=old'),
        'pi_9',
      );
      expect(built.queryParametersAll['a'], ['1', '2']);
      expect(built.queryParametersAll['uqpay_intent'], ['pi_9']);
    });
  });

  test('consume with two different ids in the URL and no slot -> null, '
      'no request', () async {
    final h = PaymentsHarness();
    final handler = UqpayReturnHandler(
      payments: h.payments,
      store: InMemoryKeyValueStore(),
    );
    expect(
      await handler.consume(
        Uri.parse('https://s/r?uqpay_intent=pi_1&uqpay_intent=pi_2'),
      ),
      isNull,
    );
    expect(h.http.requests, isEmpty);
  });
}
