import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

import 'support/fakes.dart';

void main() {
  group('UqpayConfirmRequest', () {
    test(
      'encodes the card confirm body with sorted keys and string fields',
      () {
        final request = cardConfirmRequest();
        final json = request.toJson();
        final method = json['payment_method']! as Map<String, Object?>;
        final card = method['card']! as Map<String, Object?>;

        expect(method['type'], 'card');
        expect(card['card_number'], testPan);
        expect(card['expiry_month'], '09', reason: 'string, not number');
        expect(card['expiry_year'], '2030', reason: 'string, not number');
        expect(card['cvc'], testCvc);
        expect(card['network'], 'visa');
        expect(card['auto_capture'], true);
        expect(card['authorization_type'], 'authorization');
        expect(card['three_ds_action'], 'enforce_3ds');
        expect(
          card.containsKey('three_ds'),
          isFalse,
          reason: 'absent, not null',
        );
        expect(
          (card['billing']! as Map<String, Object?>)['address'],
          containsPair('country_code', 'SG'),
        );

        final browser = json['browser_info']! as Map<String, Object?>;
        expect(browser['timezone'], '8', reason: 'whole hours as a string');
        expect(browser['screen_width'], 393, reason: 'a JSON number');
        expect(browser['screen_color_depth'], 24);
        expect(browser['language'], 'en-SG');
        expect(browser.containsKey('location'), isFalse, reason: 'never faked');
        expect(
          (browser['browser']! as Map<String, Object?>)['java_enabled'],
          false,
          reason: 'java_enabled is always sent as false',
        );
        expect(
          (browser['mobile']! as Map<String, Object?>)['os_type'],
          'IOS',
          reason: 'uppercase',
        );
        expect(json['ip_address'], '10.0.0.2');

        // Canonical bytes are sorted at every level and stable.
        final canonical = request.toCanonicalJson();
        expect(
          canonical,
          startsWith('{"browser_info":{"accept_header":"*/*",'),
        );
        expect(
          canonical,
          UqpayConfirmRequest.fromJson(
            jsonDecode(canonical) as Map<String, Object?>,
          ).toCanonicalJson(),
        );
        expect(
          UqpayConfirmRequest.fromJson(
            jsonDecode(canonical) as Map<String, Object?>,
          ),
          request,
        );
      },
    );

    test('omits ip_address when unknown, never fabricates it', () {
      final request = UqpayConfirmRequest(
        paymentMethod: cardConfirmRequest().paymentMethod,
        browserInfo: browserInfo(),
      );
      expect(request.toJson().containsKey('ip_address'), isFalse);
      expect(request.toString(), 'UqpayConfirmRequest(paymentMethod: card)');
    });

    test('card details validate structure and name the field', () {
      UqpayCardDetails build({
        String number = testPan,
        String month = '09',
        String year = '2030',
        String cvc = '123',
        String name = 'A B',
      }) => UqpayCardDetails(
        cardName: name,
        cardNumber: number,
        expiryMonth: month,
        expiryYear: year,
        cvc: cvc,
        billing: const UqpayBillingDetails(),
      );

      Matcher throwsNaming(String field) => throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', field)
            .having((e) => e.toString(), 'toString', isNot(contains(testPan))),
      );

      expect(
        () => build(number: '4242 4242 4242 4242'),
        throwsNaming('cardNumber'),
      );
      expect(() => build(number: '4242'), throwsNaming('cardNumber'));
      expect(() => build(number: '4' * 20), throwsNaming('cardNumber'));
      expect(() => build(month: '9'), throwsNaming('expiryMonth'));
      expect(() => build(year: '30'), throwsNaming('expiryYear'));
      expect(() => build(cvc: '12'), throwsNaming('cvc'));
      expect(() => build(cvc: '12345'), throwsNaming('cvc'));
      expect(() => build(name: '  '), throwsNaming('cardName'));

      final ok = build(number: '6' * 19, cvc: '1234');
      expect(ok.last4, '6666');
      expect(ok.network, isNull, reason: 'omitted rather than "unknown"');
      expect(ok.toJson().containsKey('network'), isFalse);
    });

    test('card details toString shows only network and last4', () {
      final card = cardConfirmRequest().paymentMethod.card!;
      expect(
        card.toString(),
        'UqpayCardDetails(network: visa, last4: 4242, cvc: ***)',
      );
      expect(card.toString(), isNot(contains(testPan)));
      expect(card.toString(), isNot(contains(testCvc)));
      expect(card.toString(), isNot(contains('Ada')));
    });

    test('card details fromJson requires the card fields', () {
      expect(
        () => UqpayCardDetails.fromJson(const {'card_name': 'A'}),
        throwsA(isA<FormatException>()),
      );
      final full = UqpayCardDetails.fromJson(const {
        'card_name': 'A B',
        'card_number': testPan,
        'expiry_month': '09',
        'expiry_year': '2030',
        'cvc': '123',
        'three_ds': {'return_url': 'r'},
      });
      expect(full.threeDs!.returnUrl, 'r');
      expect(full.autoCapture, isTrue);
      expect(full.toJson()['three_ds'], {'return_url': 'r'});
    });

    test('wallet payment methods emit the details under the type key', () {
      final method = UqpayConfirmPaymentMethod.wallet(
        'paynow',
        const UqpayWalletDetails(),
      );
      expect(method.toJson(), {
        'type': 'paynow',
        'paynow': {'flow': 'qrcode', 'is_present': false},
      });
      expect(method.card, isNull);
      expect(method.wallet, isNotNull);
      expect(method.toString(), 'UqpayConfirmPaymentMethod(type: paynow)');

      final wechat = UqpayConfirmPaymentMethod.wallet(
        'wechatpay',
        const UqpayWalletDetails(
          flow: 'mini_program',
          osType: 'ios',
          openId: 'o',
          shopperName: 's',
        ),
      );
      expect(wechat.toJson()['wechatpay'], {
        'flow': 'mini_program',
        'is_present': false,
        'os_type': 'ios',
        'open_id': 'o',
        'shopper_name': 's',
      });
      expect(
        UqpayConfirmPaymentMethod.fromJson(wechat.toJson()),
        wechat,
      );
      expect(UqpayWalletDetails.fromJson(const {}).flow, 'qrcode');
    });

    test('wallet construction refuses empty or card types', () {
      expect(
        () => UqpayConfirmPaymentMethod.wallet('', const UqpayWalletDetails()),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'type')),
      );
      expect(
        () => UqpayConfirmPaymentMethod.wallet(
          'card',
          const UqpayWalletDetails(),
        ),
        throwsArgumentError,
      );
    });

    test('confirm payment method fromJson needs type and details', () {
      expect(
        () => UqpayConfirmPaymentMethod.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UqpayConfirmPaymentMethod.fromJson(const {'type': 'paynow'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('paynow'),
          ),
        ),
      );
      final card = UqpayConfirmPaymentMethod.fromJson(
        cardConfirmRequest().paymentMethod.toJson(),
      );
      expect(card.card!.last4, '4242');
    });

    test('browser info sub-models round-trip and default correctly', () {
      final info = browserInfo();
      final decoded = UqpayBrowserInfo.fromJson(info.toJson());
      expect(decoded, info);

      const withOptionals = UqpayBrowserInfo(
        browser: UqpayBrowserDetails(
          userAgent: 'ua',
          javaEnabled: true,
          javascriptEnabled: false,
          cookieEnabled: false,
          plugins: ['p'],
          doNotTrack: true,
        ),
        deviceId: 'd',
        language: 'en',
        mobile: UqpayMobileDetails(
          deviceModel: 'Pixel',
          osType: 'ANDROID',
          osVersion: 'Android 15',
          carrier: 'C',
        ),
        screenHeight: 1,
        screenWidth: 2,
        timezone: '-2',
        acceptHeader: 'text/html',
        screenColorDepth: 32,
        touchSupport: false,
        location: UqpayLocation(lat: '1.29', lon: '103.85', accuracy: 10),
        fonts: ['f'],
        webglVendor: 'v',
        webglRenderer: 'r',
        hardwareConcurrency: 8,
        deviceMemory: 4,
      );
      final json = withOptionals.toJson();
      expect(json['location'], {
        'lat': '1.29',
        'lon': '103.85',
        'accuracy': 10,
      });
      expect(json['hardware_concurrency'], 8);
      expect(UqpayBrowserInfo.fromJson(json), withOptionals);
      expect(
        UqpayLocation.fromJson(const {'lat': '1', 'lon': '2'}).accuracy,
        isNull,
      );
      expect(
        UqpayMobileDetails.fromJson(
          json['mobile']! as Map<String, Object?>,
        ).carrier,
        'C',
      );
      expect(
        UqpayBrowserDetails.fromJson(const {'user_agent': 'x'}).plugins,
        isEmpty,
      );

      expect(
        () => UqpayBrowserInfo.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UqpayLocation.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UqpayMobileDetails.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UqpayConfirmRequest.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
    });

    test('normalizeLanguageTag strips extensions the API rejects', () {
      expect(UqpayBrowserInfo.normalizeLanguageTag('en_US@rg=myzzzz'), 'en-US');
      expect(UqpayBrowserInfo.normalizeLanguageTag('en_US.UTF-8'), 'en-US');
      expect(UqpayBrowserInfo.normalizeLanguageTag('zh_Hans_SG'), 'zh-Hans-SG');
      expect(UqpayBrowserInfo.normalizeLanguageTag('en-GB'), 'en-GB');
      expect(UqpayBrowserInfo.normalizeLanguageTag('fr'), 'fr');
    });
  });

  group('billing names are gateway-mandatory', () {
    const address = UqpayAddress(
      countryCode: 'US',
      state: 'CA',
      city: 'Springfield',
      street: '1 Main Street',
      postcode: '90210',
    );
    UqpayCardDetails card(String name, UqpayBillingDetails billing) =>
        UqpayCardDetails(
          cardName: name,
          cardNumber: '6250947000000014',
          expiryMonth: '12',
          expiryYear: '2033',
          cvc: '123',
          billing: billing,
        );

    test('missing first/last name are derived from the cardholder name', () {
      final json = card(
        'Test Shopper',
        const UqpayBillingDetails(email: 's@example.com', address: address),
      ).toJson();
      final billing = json['billing']! as Map<String, Object?>;
      expect(billing['first_name'], 'Test');
      expect(billing['last_name'], 'Shopper');
      expect(billing['email'], 's@example.com');
    });

    test('a multi-word surname keeps everything after the first space', () {
      final billing = card(
        'Ada King Lovelace',
        const UqpayBillingDetails(email: 's@example.com', address: address),
      ).billing;
      expect(billing.firstName, 'Ada');
      expect(billing.lastName, 'King Lovelace');
    });

    test('a single-word cardholder name is used for both, never omitted', () {
      final billing = card(
        'Madonna',
        const UqpayBillingDetails(email: 's@example.com', address: address),
      ).billing;
      expect(billing.firstName, 'Madonna');
      expect(billing.lastName, 'Madonna');
    });

    test('explicit names are never overwritten', () {
      final billing = card(
        'Card Holder',
        const UqpayBillingDetails(
          firstName: 'Given',
          lastName: 'Family',
          email: 's@example.com',
          address: address,
        ),
      ).billing;
      expect(billing.firstName, 'Given');
      expect(billing.lastName, 'Family');
    });

    test('only the missing half is filled in', () {
      final billing = card(
        'Test Shopper',
        const UqpayBillingDetails(firstName: 'Given', address: address),
      ).billing;
      expect(billing.firstName, 'Given');
      expect(billing.lastName, 'Shopper');
    });

    test('network is detected from the PAN when not supplied', () {
      expect(
        card(
          'Test Shopper',
          const UqpayBillingDetails(address: address),
        ).network,
        'unionpay',
      );
      expect(
        UqpayCardDetails(
          cardName: 'T S',
          cardNumber: '4242424242424242',
          expiryMonth: '12',
          expiryYear: '2033',
          cvc: '123',
          billing: const UqpayBillingDetails(address: address),
          network: 'mastercard',
        ).network,
        'mastercard',
        reason: 'an explicit network wins over detection',
      );
    });
  });
}
