import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';

import '../support/fakes.dart';

/// The web return leg: `consume` recognises a challenge return, recovers the
/// intent id (URL parameter first, persisted slot second) and resolves it
/// against the SERVER — never the URL.
void main() {
  late PaymentsHarness h;
  late InMemoryKeyValueStore store;
  late UqpayReturnHandler handler;

  setUp(() {
    h = PaymentsHarness();
    store = InMemoryKeyValueStore();
    handler = UqpayReturnHandler(payments: h.payments, store: store);
  });

  group('intentIdFromUri', () {
    test('reads the uqpay_intent query parameter', () {
      expect(
        UqpayReturnHandler.intentIdFromUri(
          Uri.parse('https://shop.example/return?uqpay_intent=pi_9&x=1'),
        ),
        'pi_9',
      );
    });

    test('reads the parameter from a hash-routed fragment', () {
      expect(
        UqpayReturnHandler.intentIdFromUri(
          Uri.parse('https://shop.example/#/return?uqpay_intent=pi_9'),
        ),
        'pi_9',
      );
    });

    test('missing, empty and blank values yield null', () {
      expect(
        UqpayReturnHandler.intentIdFromUri(
          Uri.parse('https://shop.example/return'),
        ),
        isNull,
      );
      expect(
        UqpayReturnHandler.intentIdFromUri(
          Uri.parse('https://shop.example/return?uqpay_intent='),
        ),
        isNull,
      );
      expect(
        UqpayReturnHandler.intentIdFromUri(
          Uri.parse('https://shop.example/return?uqpay_intent=%20'),
        ),
        isNull,
      );
    });

    test('malformed percent-encoding never throws; the undecodable value '
        'passes through opaquely (reconcile then just misses)', () {
      final uri = Uri(
        scheme: 'https',
        host: 'shop.example',
        path: '/return',
        query: 'uqpay_intent=%zz%2',
      );
      expect(() => UqpayReturnHandler.intentIdFromUri(uri), returnsNormally);
      expect(UqpayReturnHandler.intentIdFromUri(uri), '%zz%2');
    });

    test('an unparseable fragment yields null, never a throw', () {
      final uri = Uri(
        scheme: 'https',
        host: 'shop.example',
        fragment: '::%%::',
      );
      expect(() => UqpayReturnHandler.intentIdFromUri(uri), returnsNormally);
      expect(UqpayReturnHandler.intentIdFromUri(uri), isNull);
    });
  });

  group('returnUrlFor', () {
    test('appends the parameter, preserving existing ones', () {
      final built = UqpayReturnHandler.returnUrlFor(
        Uri.parse('https://shop.example/return?order=42'),
        'pi_9',
      );
      expect(built.queryParameters, {'order': '42', 'uqpay_intent': 'pi_9'});
      expect(built.host, 'shop.example');
      expect(built.path, '/return');
    });
  });

  group('consume', () {
    test(
      'URL parameter present -> reconciles that intent with the server',
      () async {
        h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

        final result = await handler.consume(
          Uri.parse(
            'https://shop.example/return?uqpay_intent=pi_123&status=failed',
          ),
        );

        expect(
          result,
          isA<UqpayPaymentCompleted>(),
          reason:
              "the URL's status=failed lie is never read; the server's "
              'SUCCEEDED wins',
        );
        expect(h.reads.single.url.path, contains('pi_123'));
      },
    );

    test(
      'no parameter, persisted slot present -> uses and clears the slot',
      () async {
        await store.write(
          UqpayRedirectChallengePresenter.pendingIntentKey,
          'pi_123',
        );
        h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

        final result = await handler.consume(
          Uri.parse('https://shop.example/return'),
        );

        expect(result, isA<UqpayPaymentCompleted>());
        expect(store.entries, isEmpty, reason: 'consumed slots are cleared');
      },
    );

    test(
      'the slot wins over a differing URL parameter (a crafted link cannot '
      'swap in another intent), and the slot is still cleared',
      () async {
        await store.write(
          UqpayRedirectChallengePresenter.pendingIntentKey,
          'pi_OLD',
        );
        h.http.enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

        await handler.consume(
          Uri.parse('https://shop.example/return?uqpay_intent=pi_123'),
        );

        expect(h.reads.single.url.path, contains('pi_OLD'));
        expect(h.reads.single.url.path, isNot(contains('pi_123')));
        expect(store.entries, isEmpty);
      },
    );

    test(
      'neither parameter nor slot -> null, and no request is sent',
      () async {
        final result = await handler.consume(
          Uri.parse('https://shop.example/some/other/page'),
        );
        expect(result, isNull);
        expect(h.http.requests, isEmpty);
      },
    );

    test(
      'a still-pending server maps to Pending whose reconcile works',
      () async {
        h.http
          ..enqueue(jsonResponse(200, intentJson(status: 'PENDING')))
          ..enqueue(jsonResponse(200, intentJson(status: 'SUCCEEDED')));

        final result = await handler.consume(
          Uri.parse('https://shop.example/return?uqpay_intent=pi_123'),
        );

        expect(result, isA<UqpayPaymentPending>());
        final pendingResult = result as UqpayPaymentPending?;
        final after = await pendingResult!.reconcile();
        expect(after, isA<UqpayPaymentCompleted>());
      },
    );

    test('a failed read maps to Pending, never a throw', () async {
      h.http.enqueue(jsonResponse(500, '{"error": "down"}'));
      final result = await handler.consume(
        Uri.parse('https://shop.example/return?uqpay_intent=pi_123'),
      );
      expect(result, isA<UqpayPaymentPending>());
    });
  });
}
