import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

void main() {
  group('UqpayAmount round-trip', () {
    // (currency, wire string, expected en_US display)
    const table = <(String, String, String)>[
      // Zero-decimal currencies.
      ('JPY', '100', '¥100'),
      ('JPY', '0', '¥0'),
      ('JPY', '1234567', '¥1,234,567'),
      ('KRW', '50000', '₩50,000'),
      ('KRW', '1', '₩1'),
      // Two-decimal currencies.
      ('USD', '8.98', r'$8.98'),
      ('USD', '0.50', r'$0.50'),
      ('USD', '0.05', r'$0.05'),
      ('USD', '1234.50', r'$1,234.50'),
      ('USD', '1000000.00', r'$1,000,000.00'),
      // intl's en_US simple symbol for SGD is "$" and for BHD/KWD "din";
      // the symbol is intl's business — the digits are ours.
      ('SGD', '8.98', r'$8.98'),
      ('SGD', '0.00', r'$0.00'),
      ('SGD', '99999999.99', r'$99,999,999.99'),
      // Three-decimal currencies.
      ('BHD', '1.500', 'din1.500'),
      ('BHD', '0.001', 'din0.001'),
      ('KWD', '12.345', 'din12.345'),
      ('KWD', '1000.000', 'din1,000.000'),
    ];

    for (final (currency, wire, display) in table) {
      test('$currency "$wire" parses, re-encodes byte-exact and formats', () {
        final amount = UqpayAmount.parse(wire);
        expect(amount.toWireString(), wire, reason: 'byte-exact round trip');
        expect(amount.toString(), wire);
        expect(amount.format(currencyCode: currency, locale: 'en_US'), display);
      });
    }

    test('scale and digit accessors reflect the wire string exactly', () {
      final amount = UqpayAmount.parse('1234.50');
      expect(amount.scale, 2);
      expect(amount.integerDigits, '1234');
      expect(amount.fractionDigits, '50');
      expect(amount.isNegative, isFalse);
      expect(amount.isZero, isFalse);

      final whole = UqpayAmount.parse('100');
      expect(whole.scale, 0);
      expect(whole.integerDigits, '100');
      expect(whole.fractionDigits, '');

      expect(UqpayAmount.parse('0.00').isZero, isTrue);
      expect(UqpayAmount.parse('0').isZero, isTrue);
    });

    test('the same code path renders every status the same amount', () {
      // The amount type has no notion of status; this pins that there is
      // exactly one parse and one format path regardless of caller.
      const wire = '8.98';
      final results = <String>{
        for (final status in UqpayIntentStatus.known)
          UqpayPaymentIntent.fromJson(<String, Object?>{
            'payment_intent_id': 'pi',
            'intent_status': status.raw,
            'amount': wire,
          }).amount!.format(currencyCode: 'USD', locale: 'en_US'),
      };
      expect(results, {r'$8.98'});
    });
  });

  group('UqpayAmount parsing strictness', () {
    for (final bad in <String>[
      '',
      ' 8.98',
      '8.98 ',
      '8,98',
      '1,234.50',
      '8.',
      '.5',
      '08.98',
      '1e3',
      r'$8.98',
      '8.98USD',
      '+8.98',
      'abc',
      'NaN',
      '--1',
    ]) {
      test('rejects "$bad"', () {
        expect(UqpayAmount.tryParse(bad), isNull);
        expect(
          () => UqpayAmount.parse(bad),
          throwsA(
            isA<FormatException>().having((e) => e.source, 'source', bad),
          ),
        );
      });
    }

    test('accepts a negative amount and reproduces it', () {
      final amount = UqpayAmount.parse('-12.34');
      expect(amount.isNegative, isTrue);
      expect(amount.toWireString(), '-12.34');
      expect(amount.format(currencyCode: 'USD', locale: 'en_US'), r'-$12.34');
    });

    test('a negative zero round-trips but compares equal to zero', () {
      final negativeZero = UqpayAmount.parse('-0.00');
      expect(negativeZero.toWireString(), '-0.00');
      expect(negativeZero, UqpayAmount.parse('0'));
      expect(negativeZero.hashCode, UqpayAmount.parse('0').hashCode);
      expect(
        negativeZero.format(currencyCode: 'USD', locale: 'en_US'),
        r'$0.00',
      );
    });
  });

  group('UqpayAmount equality and ordering', () {
    test('equal across scales, hash-consistent', () {
      expect(UqpayAmount.parse('1.5'), UqpayAmount.parse('1.50'));
      expect(
        UqpayAmount.parse('1.5').hashCode,
        UqpayAmount.parse('1.50').hashCode,
      );
      expect(UqpayAmount.parse('100'), UqpayAmount.parse('100.000'));
      expect(
        UqpayAmount.parse('100').hashCode,
        UqpayAmount.parse('100.000').hashCode,
      );
      expect(UqpayAmount.parse('0'), UqpayAmount.parse('0.000'));
      expect(UqpayAmount.parse('1.5'), isNot(UqpayAmount.parse('1.05')));
      expect(UqpayAmount.parse('1.5'), isNot(UqpayAmount.parse('-1.5')));
    });

    test('compareTo orders numerically', () {
      final sorted = <String>[
        '10',
        '9.99',
        '0.5',
        '-1',
        '9.990',
        '0.50',
      ].map(UqpayAmount.parse).toList()..sort();
      expect(sorted.map((a) => a.toWireString()), [
        '-1',
        '0.5',
        '0.50',
        '9.99',
        '9.990',
        '10',
      ]);
      expect(UqpayAmount.parse('-1').compareTo(UqpayAmount.parse('-2')), 1);
    });
  });

  group('UqpayAmount.format locale handling', () {
    test('uses locale grouping, separators and digits', () {
      final amount = UqpayAmount.parse('1234.50');
      final german = amount.format(currencyCode: 'EUR', locale: 'de_DE');
      expect(german, startsWith('1.234,50'));
      expect(german, endsWith('€'));
      final french = amount.format(currencyCode: 'EUR', locale: 'fr_FR');
      expect(french, contains('234,50'));
      expect(french, endsWith('€'));
      // Arabic-Indic digits: the spliced fraction must be localised too.
      final arabic = amount.format(currencyCode: 'USD', locale: 'ar_EG');
      expect(arabic, contains('٥٠'));
      expect(arabic, isNot(contains('50')));
    });

    test('an unknown locale falls back instead of throwing', () {
      expect(
        UqpayAmount.parse('8.98').format(currencyCode: 'USD', locale: 'xx_YY'),
        r'$8.98',
      );
    });

    test('a null locale uses the default locale', () {
      expect(
        UqpayAmount.parse('8.98').format(currencyCode: 'USD'),
        contains('8.98'),
      );
    });

    test('an astronomically large amount falls back to the wire form', () {
      final huge = '1${'0' * 30}.99';
      expect(
        UqpayAmount.parse(huge).format(currencyCode: 'USD', locale: 'en_US'),
        'USD $huge',
      );
    });
  });
}
