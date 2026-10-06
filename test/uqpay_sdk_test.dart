import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

void main() {
  // `defaultTargetPlatform` reports Android inside `flutter test`; pin it
  // anyway so a supported-platform test can never accidentally depend on the
  // host machine.
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('UqpaySdk.init', () {
    test('resolves the origin for the requested environment', () {
      expect(
        UqpaySdk.init(environment: UqpayEnvironment.sandbox).baseUrl,
        'https://api-sandbox.uqpaytech.com',
      );
      expect(
        UqpaySdk.init(environment: UqpayEnvironment.production).baseUrl,
        'https://api.uqpay.com',
      );
    });

    test('reports that it is not using a custom origin by default', () {
      final sdk = UqpaySdk.init(environment: UqpayEnvironment.sandbox);

      expect(sdk.environment, UqpayEnvironment.sandbox);
      expect(sdk.usesCustomBaseUrl, isFalse);
    });

    test('is idempotent — two identical calls produce equal handles', () {
      final first = UqpaySdk.init(environment: UqpayEnvironment.sandbox);
      final second = UqpaySdk.init(environment: UqpayEnvironment.sandbox);

      expect(second, equals(first));
      expect(second.hashCode, equals(first.hashCode));
    });

    test('is re-initialisable with a different environment', () {
      final sandbox = UqpaySdk.init(environment: UqpayEnvironment.sandbox);
      final production = UqpaySdk.init(
        environment: UqpayEnvironment.production,
      );

      expect(production, isNot(equals(sandbox)));
      expect(sandbox.baseUrl, 'https://api-sandbox.uqpaytech.com');
      expect(production.baseUrl, 'https://api.uqpay.com');
    });
  });

  group('UqpaySdk.init validation', () {
    test('an empty baseUrlOverride throws naming the field', () {
      expect(
        () => UqpaySdk.init(
          environment: UqpayEnvironment.sandbox,
          baseUrlOverride: '   ',
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'baseUrlOverride')
              .having(
                (e) => e.toString(),
                'toString',
                contains('baseUrlOverride'),
              ),
        ),
      );
    });

    test('a relative baseUrlOverride throws naming the field', () {
      expect(
        () => UqpaySdk.init(
          environment: UqpayEnvironment.sandbox,
          baseUrlOverride: 'api.uqpay.com',
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'baseUrlOverride'),
        ),
      );
    });

    test('a non-https baseUrlOverride throws naming the field and scheme', () {
      expect(
        () => UqpaySdk.init(
          environment: UqpayEnvironment.sandbox,
          baseUrlOverride: 'http://api.uqpay.com',
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'baseUrlOverride')
              .having(
                (e) => e.message.toString(),
                'message',
                contains('https'),
              ),
        ),
      );
    });

    test('a valid https baseUrlOverride is accepted and normalised', () {
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        baseUrlOverride: 'https://api-staging.uqpaytech.com/',
      );

      expect(sdk.baseUrl, 'https://api-staging.uqpaytech.com');
      expect(sdk.usesCustomBaseUrl, isTrue);
      expect(sdk.environment, UqpayEnvironment.sandbox);
    });
  });

  group('unsupported platforms', () {
    const desktop = <TargetPlatform, String>{
      TargetPlatform.macOS: 'macOS',
      TargetPlatform.windows: 'Windows',
      TargetPlatform.linux: 'Linux',
      TargetPlatform.fuchsia: 'Fuchsia',
    };

    for (final entry in desktop.entries) {
      test('init on ${entry.value} throws UnsupportedError naming it', () {
        debugDefaultTargetPlatformOverride = entry.key;

        expect(
          () => UqpaySdk.init(environment: UqpayEnvironment.sandbox),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains(entry.value),
            ),
          ),
        );
      });
    }

    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test('init on $platform succeeds', () {
        debugDefaultTargetPlatformOverride = platform;

        expect(
          UqpaySdk.init(environment: UqpayEnvironment.sandbox).baseUrl,
          'https://api-sandbox.uqpaytech.com',
        );
      });
    }
  });

  group('UqpaySdk.init optional identifiers', () {
    test('clientId and onBehalfOf are trimmed and kept', () {
      final sdk = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        clientId: ' client-1 ',
        onBehalfOf: 'acct_sub ',
      );
      expect(sdk.clientId, 'client-1');
      expect(sdk.onBehalfOf, 'acct_sub');
      expect(sdk.tokenProvider, isNull);
      expect(sdk.toString(), isNot(contains('client-1')));
    });

    test('a blank clientId or onBehalfOf throws naming the field', () {
      expect(
        () => UqpaySdk.init(
          environment: UqpayEnvironment.sandbox,
          clientId: '  ',
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'clientId')),
      );
      expect(
        () => UqpaySdk.init(
          environment: UqpayEnvironment.sandbox,
          onBehalfOf: '',
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'onBehalfOf'),
        ),
      );
    });

    test('handles differing only in identifiers are not equal', () {
      final a = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        clientId: 'a',
      );
      final b = UqpaySdk.init(
        environment: UqpayEnvironment.sandbox,
        clientId: 'b',
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(b.hashCode));
    });
  });
}
