import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_formatters.dart';
import 'package:uqpay_sdk_flutter/src/sheet/card/card_validation.dart';
import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';

/// 100 %-coverage unit tests for card validation (Luhn + brand +
/// CVC length) and the input formatters.
void main() {
  group('brand detection', () {
    UqpayCardBrand? brandOf(String d) => UqpayCardValidator.detectBrand(d);

    test('detects each supported scheme from its BIN range', () {
      expect(brandOf('4242424242424242'), UqpayCardBrand.visa);
      expect(brandOf('4'), UqpayCardBrand.visa);
      expect(brandOf('5555555555554444'), UqpayCardBrand.mastercard);
      expect(brandOf('2221000000000009'), UqpayCardBrand.mastercard);
      expect(brandOf('2720999999999999'), UqpayCardBrand.mastercard);
      expect(brandOf('378282246310005'), UqpayCardBrand.amex);
      expect(brandOf('340000000000009'), UqpayCardBrand.amex);
      expect(brandOf('6011111111111117'), UqpayCardBrand.discover);
      expect(brandOf('6511111111111119'), UqpayCardBrand.discover);
      expect(brandOf('6440000000000000'), UqpayCardBrand.discover);
      expect(brandOf('3530111333300000'), UqpayCardBrand.jcb);
      expect(brandOf('30569309025904'), UqpayCardBrand.dinersClub);
      expect(brandOf('36700102000000'), UqpayCardBrand.dinersClub);
      expect(brandOf('6250941006528599'), UqpayCardBrand.unionPay);
    });

    test('62-prefix goes to UnionPay, not Discover', () {
      expect(brandOf('6221260000000000'), UqpayCardBrand.unionPay);
    });

    test('a single ambiguous digit claims no brand', () {
      expect(brandOf('3'), isNull);
      expect(brandOf('5'), isNull);
      expect(brandOf('6'), isNull);
      expect(brandOf(''), isNull);
    });

    test('unmatched prefixes claim no brand', () {
      expect(brandOf('31'), isNull);
      expect(brandOf('7999'), isNull);
      expect(brandOf('1234'), isNull);
      expect(brandOf('9999999999999999'), isNull);
    });

    test('partial prefixes resolve as more digits arrive', () {
      expect(brandOf('35'), UqpayCardBrand.jcb);
      expect(brandOf('3528'), UqpayCardBrand.jcb);
      expect(brandOf('3527'), isNull); // outside 3528–3589
      expect(brandOf('22'), UqpayCardBrand.mastercard);
      expect(brandOf('2220'), isNull); // outside 2221–2720
      expect(brandOf('30'), UqpayCardBrand.dinersClub);
    });
  });

  group('Luhn', () {
    test('accepts valid numbers and rejects a one-digit tweak', () {
      expect(UqpayCardValidator.passesLuhn('4242424242424242'), isTrue);
      expect(UqpayCardValidator.passesLuhn('4242424242424241'), isFalse);
      expect(UqpayCardValidator.passesLuhn(''), isFalse);
      expect(UqpayCardValidator.passesLuhn('42a2424242424242'), isFalse);
    });
  });

  group('number validation', () {
    test('a 19-digit UnionPay PAN is VALID — never capped at 16 '
        '(regression seen in another platform SDK)', () {
      const pan19 = '6212345678901234569';
      expect(pan19.length, 19);
      expect(UqpayCardValidator.detectBrand(pan19), UqpayCardBrand.unionPay);
      expect(
        UqpayCardValidator.validateNumber(pan19),
        UqpayCardFieldValidity.valid,
      );
    });

    test('a 17-digit UnionPay PAN is valid', () {
      expect(
        UqpayCardValidator.validateNumber('62509410065285998'),
        UqpayCardFieldValidity.valid,
      );
    });

    test('a complete 16-digit Visa is valid', () {
      expect(
        UqpayCardValidator.validateNumber('4242424242424242'),
        UqpayCardFieldValidity.valid,
      );
    });

    test('a 13-digit Visa is valid', () {
      expect(
        UqpayCardValidator.validateNumber('4222222222222'),
        UqpayCardFieldValidity.valid,
      );
    });

    test('a short number is incomplete, not invalid', () {
      expect(
        UqpayCardValidator.validateNumber('42424242'),
        UqpayCardFieldValidity.incomplete,
      );
      expect(
        UqpayCardValidator.validateNumber(''),
        UqpayCardFieldValidity.incomplete,
      );
    });

    test('a Luhn-failing number at max length is invalid', () {
      expect(
        UqpayCardValidator.validateNumber('5555555555554445'),
        UqpayCardFieldValidity.invalid,
      );
    });

    test('a Luhn-failing Visa at 16 digits is incomplete (19 possible)', () {
      expect(
        UqpayCardValidator.validateNumber('4242424242424241'),
        UqpayCardFieldValidity.incomplete,
      );
    });
  });

  group('grouping', () {
    test('groups of four for most schemes, including 19 digits', () {
      expect(
        UqpayCardValidator.groupNumber(
          '6212345678901234569',
          UqpayCardBrand.unionPay,
        ),
        '6212 3456 7890 1234 569',
      );
      expect(
        UqpayCardValidator.groupNumber('42424242', UqpayCardBrand.visa),
        '4242 4242',
      );
    });

    test('4-6-5 for American Express', () {
      expect(
        UqpayCardValidator.groupNumber('378282246310005', UqpayCardBrand.amex),
        '3782 822463 10005',
      );
    });

    test('4-6-4 for a 14-digit Diners Club', () {
      expect(
        UqpayCardValidator.groupNumber(
          '30569309025904',
          UqpayCardBrand.dinersClub,
        ),
        '3056 930902 5904',
      );
    });

    test('no brand falls back to groups of four', () {
      expect(UqpayCardValidator.groupNumber('12345', null), '1234 5');
    });
  });

  group('expiry validation', () {
    final now = DateTime.utc(2026, 8, 18);

    UqpayCardFieldValidity validate(String mmyy) =>
        UqpayCardValidator.validateExpiry(mmyy, now);

    test('a future date is valid', () {
      expect(validate('1230'), UqpayCardFieldValidity.valid);
      expect(validate('0926'), UqpayCardFieldValidity.valid);
    });

    test('the current month is still valid', () {
      expect(validate('0826'), UqpayCardFieldValidity.valid);
    });

    test('a past month is expired (past-date rejection)', () {
      expect(validate('0726'), UqpayCardFieldValidity.expired);
      expect(validate('1225'), UqpayCardFieldValidity.expired);
    });

    test('impossible months are invalid', () {
      expect(validate('0026'), UqpayCardFieldValidity.invalid);
      expect(validate('1326'), UqpayCardFieldValidity.invalid);
    });

    test('partial input is incomplete', () {
      expect(validate(''), UqpayCardFieldValidity.incomplete);
      expect(validate('1'), UqpayCardFieldValidity.incomplete);
      expect(validate('12'), UqpayCardFieldValidity.incomplete);
      expect(validate('123'), UqpayCardFieldValidity.incomplete);
    });

    test('a first digit that can never start a month is invalid', () {
      expect(validate('2'), UqpayCardFieldValidity.invalid);
    });
  });

  group('CVC validation', () {
    test('3 digits for most brands, 4 for Amex', () {
      expect(
        UqpayCardValidator.validateCvc('737', UqpayCardBrand.visa),
        UqpayCardFieldValidity.valid,
      );
      expect(
        UqpayCardValidator.validateCvc('7373', UqpayCardBrand.amex),
        UqpayCardFieldValidity.valid,
      );
      expect(
        UqpayCardValidator.validateCvc('737', UqpayCardBrand.amex),
        UqpayCardFieldValidity.incomplete,
      );
      expect(
        UqpayCardValidator.validateCvc('7373', UqpayCardBrand.visa),
        UqpayCardFieldValidity.invalid,
      );
    });

    test('with no brand, 3 or 4 digits are accepted', () {
      expect(
        UqpayCardValidator.validateCvc('123', null),
        UqpayCardFieldValidity.valid,
      );
      expect(
        UqpayCardValidator.validateCvc('1234', null),
        UqpayCardFieldValidity.valid,
      );
      expect(
        UqpayCardValidator.validateCvc('12', null),
        UqpayCardFieldValidity.incomplete,
      );
      expect(
        UqpayCardValidator.validateCvc('12345', null),
        UqpayCardFieldValidity.invalid,
      );
    });

    test('empty is incomplete', () {
      expect(
        UqpayCardValidator.validateCvc('', UqpayCardBrand.visa),
        UqpayCardFieldValidity.incomplete,
      );
    });
  });

  group('input formatters', () {
    TextEditingValue format(TextInputFormatter formatter, String text) =>
        formatter.formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );

    test('card number formatter groups and strips junk', () {
      final formatter = UqpayCardNumberFormatter();
      expect(format(formatter, '4242424242424242').text, '4242 4242 4242 4242');
      expect(format(formatter, '4242-4242 42ab').text, '4242 4242 42');
    });

    test('card number formatter allows 19 UnionPay digits and caps there', () {
      final formatter = UqpayCardNumberFormatter();
      expect(
        format(formatter, '62123456789012345699999').text,
        '6212 3456 7890 1234 569',
      );
    });

    test('card number formatter caps Amex at 15', () {
      final formatter = UqpayCardNumberFormatter();
      expect(format(formatter, '3782822463100059').text, '3782 822463 10005');
    });

    test('caret lands after the typed digits', () {
      final formatter = UqpayCardNumberFormatter();
      final value = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: '42424',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      expect(value.text, '4242 4');
      expect(value.selection.baseOffset, 6);
    });

    test('expiry formatter inserts the slash and zero-pads', () {
      final formatter = UqpayExpiryDateFormatter();
      expect(format(formatter, '9').text, '09');
      expect(format(formatter, '12').text, '12');
      expect(format(formatter, '1230').text, '12/30');
      expect(format(formatter, '12305').text, '12/30');
      expect(format(formatter, '1').text, '1');
    });

    test('expiry formatter lets deletion remove the zero-pad', () {
      final formatter = UqpayExpiryDateFormatter();
      final value = formatter.formatEditUpdate(
        const TextEditingValue(text: '09'),
        const TextEditingValue(
          text: '0',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(value.text, '0');
    });

    test('cvc formatter is digits-only and capped', () {
      final formatter = UqpayCvcFormatter(maxLength: 3);
      expect(format(formatter, '12a34').text, '123');
      expect(format(formatter, '12').text, '12');
    });
  });

  group('billing email', () {
    // The gateway answers `invalid_payment_method: invalid billing.email`
    // for a card confirm with no usable email, which fails the whole
    // payment — so the form refuses to submit without one.
    UqpayCardFieldValidity validity(String v) =>
        UqpayCardValidator.validateEmail(v);

    test('accepts ordinary addresses', () {
      for (final address in <String>[
        'ada@example.com',
        'ada.lovelace+uqpay@example.co.uk',
        'a@b.io',
        '  ada@example.com  ', // surrounding whitespace is trimmed
        "o'hara@example.com",
      ]) {
        expect(
          validity(address),
          UqpayCardFieldValidity.valid,
          reason: address,
        );
      }
    });

    test('an empty field is incomplete, not invalid', () {
      // Untouched fields must not shout at the customer before they type.
      expect(validity(''), UqpayCardFieldValidity.incomplete);
      expect(validity('   '), UqpayCardFieldValidity.incomplete);
    });

    test('rejects addresses the gateway would reject', () {
      for (final address in <String>[
        'ada',
        'ada@',
        '@example.com',
        'ada@example',
        'ada@@example.com',
        'ada@example..com',
        'ada@example.c',
        'ada lovelace@example.com',
      ]) {
        expect(
          validity(address),
          isNot(UqpayCardFieldValidity.valid),
          reason: address,
        );
      }
    });
  });
}
