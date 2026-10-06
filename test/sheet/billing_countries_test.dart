import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/billing_countries.dart';

/// The country table is data, and data rots quietly. These tests are the
/// guard the native SDKs get for free by reading the platform's ISO list.
///
/// The count and the spot checks come from `java.util.Locale.getISOCountries`
/// on the JDK shipped with Android Studio — the same
/// source the UQPAY Android SDK reads at runtime.
void main() {
  group('billing countries', () {
    test('carries the full ISO 3166-1 alpha-2 set', () {
      expect(UqpayBillingCountries.all, hasLength(249));
    });

    test('every code is a distinct uppercase alpha-2 with a name', () {
      final codes = <String>{};
      for (final country in UqpayBillingCountries.all) {
        expect(
          country.code,
          matches(RegExp(r'^[A-Z]{2}$')),
          reason: country.toString(),
        );
        expect(country.name.trim(), isNotEmpty, reason: country.code);
        expect(
          codes.add(country.code),
          isTrue,
          reason: 'duplicate ${country.code}',
        );
      }
    });

    test('includes the entries a hand-written list always forgets', () {
      // The four the iOS SDK's nine-entry table could never have had, plus
      // the ones that are easy to drop when transcribing by hand.
      for (final code in <String>['AX', 'BQ', 'SX', 'TL', 'CC', 'ZW', 'YT']) {
        expect(
          UqpayBillingCountries.lookup(code)?.code,
          code,
          reason: 'missing $code',
        );
      }
    });

    test('is sorted by display name', () {
      final names = UqpayBillingCountries.all
          .map((country) => country.name)
          .toList();
      expect(names, orderedEquals(List<String>.of(names)..sort()));
    });

    test('lookup is case-insensitive and never substitutes', () {
      expect(UqpayBillingCountries.lookup('sg')?.name, 'Singapore');
      expect(UqpayBillingCountries.lookup('SG')?.name, 'Singapore');
      // The iOS defect this table exists to avoid: an unknown code must not
      // quietly become the United States (or anything else).
      expect(UqpayBillingCountries.lookup('ZZ'), isNull);
      expect(UqpayBillingCountries.lookup('XX'), isNull);
      expect(UqpayBillingCountries.lookup(''), isNull);
      expect(UqpayBillingCountries.lookup(null), isNull);
      expect(UqpayBillingCountries.lookup('SGP'), isNull);
    });
  });
}
