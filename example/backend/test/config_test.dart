import 'package:test/test.dart';
import 'package:uqpay_reference_backend/uqpay_reference_backend.dart';

import 'helpers.dart';

void main() {
  group('BackendConfig.fromEnvironment', () {
    test('parses a minimal sandbox environment with defaults', () {
      final config = BackendConfig.fromEnvironment(baseEnv());
      expect(config.environment, 'sandbox');
      expect(config.apiBaseUrl.toString(), 'https://api-sandbox.uqpaytech.com');
      expect(config.port, 8787);
      expect(config.onBehalfOf, isNull);
      expect(config.webhookUrl, isNull);
    });

    test('refuses to start without UQPAY_CLIENT_ID, naming the variable', () {
      final env = baseEnv()..remove('UQPAY_CLIENT_ID');
      expect(
        () => BackendConfig.fromEnvironment(env),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('UQPAY_CLIENT_ID'),
          ),
        ),
      );
    });

    test('refuses to start without UQPAY_API_KEY, naming the variable', () {
      final env = baseEnv()..['UQPAY_API_KEY'] = '   ';
      expect(
        () => BackendConfig.fromEnvironment(env),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('UQPAY_API_KEY'),
          ),
        ),
      );
    });

    test('refuses production unless UQPAY_ALLOW_PRODUCTION=1', () {
      expect(
        () => BackendConfig.fromEnvironment(
          baseEnv(extra: {'UQPAY_ENVIRONMENT': 'production'}),
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('UQPAY_ALLOW_PRODUCTION'),
          ),
        ),
      );

      final allowed = BackendConfig.fromEnvironment(
        baseEnv(
          extra: {
            'UQPAY_ENVIRONMENT': 'production',
            'UQPAY_ALLOW_PRODUCTION': '1',
          },
        ),
      );
      expect(allowed.environment, 'production');
      expect(allowed.apiBaseUrl.toString(), 'https://api.uqpay.com');
    });

    test('rejects unknown environments', () {
      expect(
        () => BackendConfig.fromEnvironment(
          baseEnv(extra: {'UQPAY_ENVIRONMENT': 'staging'}),
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('honours https base-url override and rejects http', () {
      final ok = BackendConfig.fromEnvironment(
        baseEnv(
          extra: {'UQPAY_API_BASE_URL_OVERRIDE': 'https://api.example.test'},
        ),
      );
      expect(ok.apiBaseUrl.host, 'api.example.test');
      expect(
        () => BackendConfig.fromEnvironment(
          baseEnv(
            extra: {'UQPAY_API_BASE_URL_OVERRIDE': 'http://api.example.test'},
          ),
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('reads PORT and on-behalf-of', () {
      final config = BackendConfig.fromEnvironment(
        baseEnv(extra: {'PORT': '9000', 'UQPAY_ON_BEHALF_OF': 'acct_sub_1'}),
      );
      expect(config.port, 9000);
      expect(config.onBehalfOf, 'acct_sub_1');
    });
  });

  test('mask keeps only the last four characters', () {
    expect(mask('sk_test_not_a_real_key_wxyz'), '****wxyz');
    expect(mask('abc'), '****');
    expect(mask(null), '<unset>');
  });
}
