import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

void main() {
  group('test harness', () {
    test('runs', () {
      // Placeholder proving `flutter test` is wired up. Replaced by real
      // coverage as the phases land; kept so the harness itself is never the
      // reason CI is green.
      expect(UqpayEnvironment.values, hasLength(2));
    });
  });

  group('UqpayEnvironment', () {
    test('sandbox resolves to the sandbox origin', () {
      expect(
        UqpayEnvironment.sandbox.baseUrl,
        'https://api-sandbox.uqpaytech.com',
      );
    });

    test('production resolves to the production origin', () {
      expect(UqpayEnvironment.production.baseUrl, 'https://api.uqpay.com');
    });

    test('every origin is https with no trailing slash or path', () {
      for (final environment in UqpayEnvironment.values) {
        final uri = environment.baseUri;
        expect(
          uri.scheme,
          'https',
          reason: '${environment.name} must be https',
        );
        expect(uri.host, isNotEmpty);
        expect(
          uri.path,
          isEmpty,
          reason: '${environment.name} must be origin only',
        );
        expect(environment.baseUrl, isNot(endsWith('/')));
      }
    });
  });
}
