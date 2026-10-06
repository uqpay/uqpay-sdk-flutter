import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';
import 'package:uqpay_sdk_flutter_example/src/config/app_config.dart';

void main() {
  group('AppConfig.resolve', () {
    test('defaults to sandbox and the local backend', () {
      final config = AppConfig.resolve(
        environment: 'sandbox',
        backendUrl: AppConfig.defaultBackendUrl,
        onBehalfOf: '',
      );

      expect(config.configuredEnvironment, UqpayEnvironment.sandbox);
      expect(config.backendBaseUrl, 'http://localhost:8787');
      expect(config.onBehalfOf, isNull);
      expect(config.environmentRecognised, isTrue);
      expect(config.backendUrlRecognised, isTrue);
      expect(config.productionRequested, isFalse);
      expect(config.backendIsLoopback, isTrue);
    });

    test('recognises production and reports it', () {
      final config = AppConfig.resolve(
        environment: 'PRODUCTION',
        backendUrl: 'https://pay.example.com/',
        onBehalfOf: ' acct_123 ',
      );

      expect(config.configuredEnvironment, UqpayEnvironment.production);
      expect(config.productionRequested, isTrue);
      // Trailing slash removed so path concatenation cannot double up.
      expect(config.backendBaseUrl, 'https://pay.example.com');
      expect(config.onBehalfOf, 'acct_123');
      expect(config.backendIsLoopback, isFalse);
    });

    test('a typo never silently targets production', () {
      final config = AppConfig.resolve(
        environment: 'produciton',
        backendUrl: AppConfig.defaultBackendUrl,
        onBehalfOf: '',
      );

      expect(config.configuredEnvironment, UqpayEnvironment.sandbox);
      expect(config.environmentRecognised, isFalse);
      expect(config.rawEnvironment, 'produciton');
    });

    test('an unusable backend URL falls back and says so', () {
      for (final bad in <String>['', '   ', 'localhost:8787', 'ftp://x/y']) {
        final config = AppConfig.resolve(
          environment: 'sandbox',
          backendUrl: bad,
          onBehalfOf: '',
        );
        expect(config.backendUrlRecognised, isFalse, reason: bad);
        expect(config.backendBaseUrl, AppConfig.defaultBackendUrl);
      }
    });
  });

  test('the app reads no credential from the build environment', () {
    final offenders = <String>[];
    for (final entity in _libSources()) {
      final source = entity.readAsStringSync();
      for (final banned in const <String>[
        'UQPAY_API_KEY',
        'UQPAY_CLIENT_ID',
        'UQPAY_CLIENT_SECRET',
        'x-api-key',
      ]) {
        if (source.contains(banned)) {
          offenders.add('${entity.path} mentions $banned');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  // `--dart-define-from-file=app.env` only stays safe while the app reads
  // nothing but the three app keys: a define reaches the compiled app only
  // through a `fromEnvironment` lookup, so this pins every lookup under lib/
  // (any `String`/`bool`/`int`.fromEnvironment or `hasEnvironment`, however
  // the formatter wraps the call) to that allow-list.
  test('every fromEnvironment lookup under lib/ is one of the app keys', () {
    const allowed = <String>{
      'UQPAY_ENVIRONMENT',
      'UQPAY_MERCHANT_BACKEND_URL',
      'UQPAY_ON_BEHALF_OF',
    };
    final lookup = RegExp(
      r'''(?:fromEnvironment|hasEnvironment)\s*\(\s*(?:r?['"]([^'"]*)['"]|([^)'"\s,]+))''',
    );
    final seen = <String>{};
    final offenders = <String>[];
    for (final entity in _libSources()) {
      final source = entity.readAsStringSync();
      for (final match in lookup.allMatches(source)) {
        final key = match.group(1);
        if (key == null) {
          // A non-literal key could be anything, so it is not allowed.
          offenders.add('${entity.path}: non-literal key ${match.group(2)}');
        } else if (!allowed.contains(key)) {
          offenders.add('${entity.path}: reads $key');
        } else {
          seen.add(key);
        }
      }
    }
    expect(offenders, isEmpty);
    // Guards the regex itself: if it stopped matching, the test above would
    // pass vacuously.
    expect(seen, allowed);
  });

  test('Platform.environment is never read by the app', () {
    for (final entity in _libSources()) {
      expect(
        entity.readAsStringSync().contains('Platform.environment'),
        isFalse,
        reason: entity.path,
      );
    }
  });
}

Iterable<File> _libSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));
