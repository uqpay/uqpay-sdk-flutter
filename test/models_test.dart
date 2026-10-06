import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

import 'support/fakes.dart';

void main() {
  group('UqpayPaymentIntent', () {
    test('decodes the union of both Swift decodings with explicit keys', () {
      final json = intentJson(
        status: 'REQUIRES_CUSTOMER_ACTION',
        attempt: <String, Object?>{
          'attempt_id': 'att_1',
          'payment_intent_id': 'pi_123',
          'attempt_status': 'FAILED',
          'amount': '8.98',
          'currency': 'SGD',
          'captured_amount': '0.00',
          'refunded_amount': '0.00',
          'auth_code': 'A1',
          'arn': 'arn',
          'rrn': 'rrn',
          'advice_code': '',
          'failure_code': '3ds_failed',
          'failure_message': '',
          'authentication_data': <String, Object?>{
            'cvv_result': 'M',
            'avs_result': 'Y',
            'three_ds': <String, Object?>{
              'three_ds_version': '2.2.0',
              'cavv': 'c',
              'eci': '05',
              'ds_transaction_id': 'ds',
              'three_ds_authentication_status': 'Y',
              'three_ds_cancellation_reason': null,
            },
          },
          'create_time': 't1',
          'update_time': 't2',
          'complete_time': 't3',
          'cancel_time': null,
          'cancellation_reason': null,
        },
        nextAction: <String, Object?>{
          'type': 'redirect_to_url',
          'redirect_to_url': <String, Object?>{
            'url': 'https://acs.example/challenge',
            'return_url': 'myapp://payment',
          },
        },
      );
      json['payment_method'] = <String, Object?>{
        'type': 'card',
        'card': <String, Object?>{
          'card_name': 'Ada Lovelace',
          'card_number': '424242******4242',
          'network': 'visa',
          'billing': <String, Object?>{
            'first_name': 'Ada',
            'address': <String, Object?>{'country_code': 'SG'},
          },
          'auto_capture': true,
          'authorization_type': 'authorization',
          'three_ds_action': 'enforce_3ds',
          'three_ds': <String, Object?>{'return_url': 'myapp://payment'},
        },
      };
      json['customer'] = <String, Object?>{
        'first_name': 'Ada',
        'email': 'ada@example.com',
        'address': <String, Object?>{'city': 'Singapore'},
        'metadata': <String, Object?>{'tier': 'gold', 'bad': 3},
      };
      json['customer_id'] = 'cus_1';

      final intent = UqpayPaymentIntent.fromJson(json);

      expect(intent.id, 'pi_123');
      expect(intent.status, UqpayIntentStatus.requiresCustomerAction);
      expect(intent.amount, UqpayAmount.parse('8.98'));
      expect(intent.amount!.toWireString(), '8.98');
      expect(intent.currency, 'SGD');
      expect(intent.capturedAmount!.toWireString(), '0.00');
      expect(intent.clientSecret, 'cs_secret');
      expect(intent.merchantOrderId, 'order-1');
      expect(intent.description, 'Coffee');
      expect(intent.metadata, {'k': 'v'});
      expect(intent.returnUrl, 'myapp://payment');
      expect(intent.createTime, '2026-08-18T12:00:00Z');
      expect(intent.updateTime, '2026-08-18T12:00:01Z');
      expect(intent.completeTime, isNull);
      expect(intent.availablePaymentMethodTypes, ['card', 'paynow']);
      expect(intent.customerId, 'cus_1');

      final method = intent.paymentMethod!;
      expect(method.type, 'card');
      expect(method.card!.cardName, 'Ada Lovelace');
      expect(method.card!.maskedCardNumber, '424242******4242');
      expect(method.card!.network, 'visa');
      expect(method.card!.billing!.firstName, 'Ada');
      expect(method.card!.billing!.address!.countryCode, 'SG');
      expect(method.card!.autoCapture, isTrue);
      expect(method.card!.authorizationType, 'authorization');
      expect(method.card!.threeDsAction, 'enforce_3ds');
      expect(method.card!.threeDs!.returnUrl, 'myapp://payment');
      expect(method.toString(), 'UqpayPaymentMethod(type: card)');
      expect(method.card.toString(), 'UqpayCardPaymentMethod(network: visa)');

      final customer = intent.customer!;
      expect(customer.firstName, 'Ada');
      expect(customer.email, 'ada@example.com');
      expect(customer.address!.city, 'Singapore');
      expect(customer.metadata, {'tier': 'gold'});
      expect(customer.toString(), 'UqpayCustomer(redacted)');

      final attempt = intent.latestPaymentAttempt!;
      expect(attempt.attemptId, 'att_1');
      expect(attempt.paymentIntentId, 'pi_123');
      expect(attempt.status, UqpayAttemptStatus.failed);
      expect(attempt.isFailed, isTrue);
      expect(attempt.amount!.toWireString(), '8.98');
      expect(attempt.capturedAmount!.toWireString(), '0.00');
      expect(attempt.refundedAmount!.toWireString(), '0.00');
      expect(attempt.authCode, 'A1');
      expect(attempt.arn, 'arn');
      expect(attempt.rrn, 'rrn');
      expect(attempt.adviceCode, isNull, reason: 'empty → null');
      expect(attempt.failureCode, '3ds_failed');
      expect(attempt.failureMessage, isNull, reason: 'empty → null');
      expect(attempt.authenticationData!.cvvResult, 'M');
      expect(attempt.authenticationData!.avsResult, 'Y');
      expect(attempt.authenticationData!.threeDs!.threeDsVersion, '2.2.0');
      expect(attempt.authenticationData!.threeDs!.cavv, 'c');
      expect(attempt.authenticationData!.threeDs!.eci, '05');
      expect(attempt.authenticationData!.threeDs!.dsTransactionId, 'ds');
      expect(attempt.authenticationData!.threeDs!.authenticationStatus, 'Y');
      expect(attempt.authenticationData!.threeDs!.cancellationReason, isNull);
      expect(attempt.createTime, 't1');
      expect(attempt.updateTime, 't2');
      expect(attempt.completeTime, 't3');
      expect(attempt.cancelTime, isNull);
      expect(attempt.cancellationReason, isNull);
      expect(
        attempt.toString(),
        'UqpayPaymentAttempt(id: att_1, status: FAILED, '
        'failureCode: 3ds_failed)',
      );

      final action = intent.nextAction!;
      expect(action.type, UqpayNextActionType.redirectToUrl);
      expect(action.rawType, 'redirect_to_url');
      expect(action.redirectToUrl!.url, 'https://acs.example/challenge');
      expect(action.redirectToUrl!.returnUrl, 'myapp://payment');
      expect(action.toString(), 'UqpayNextAction(type: redirect_to_url)');

      expect(
        intent.toString(),
        'UqpayPaymentIntent(id: pi_123, status: REQUIRES_CUSTOMER_ACTION)',
      );
    });

    test('toJson → fromJson round-trips to an equal model', () {
      final json = intentJson(
        status: 'SUCCEEDED',
        attempt: <String, Object?>{
          'attempt_id': 'att_1',
          'attempt_status': 'SUCCEEDED',
          'amount': '8.98',
        },
        nextAction: <String, Object?>{
          'display_qr_code': <String, Object?>{
            'qr_code': '00020101021226...',
            'expires_at': '2026-08-18T12:10:00Z',
          },
        },
      );
      final intent = UqpayPaymentIntent.fromJson(json);
      final again = UqpayPaymentIntent.fromJson(
        jsonDecode(jsonEncode(intent.toJson())) as Map<String, Object?>,
      );
      expect(again, intent);
      expect(again.hashCode, intent.hashCode);
      expect(again.toCanonicalJson(), intent.toCanonicalJson());
      // Number-as-string fields are echoed verbatim.
      expect(intent.toJson()['amount'], '8.98');
      expect(intent.toJson()['captured_amount'], '0.00');
      // Absent fields are absent, not null.
      expect(intent.toJson().containsKey('complete_time'), isFalse);
      expect(intent.toJson().containsKey('customer'), isFalse);
    });

    test('only payment_intent_id and intent_status are required', () {
      final minimal = UqpayPaymentIntent.fromJson(const <String, Object?>{
        'payment_intent_id': 'pi_1',
        'intent_status': 'PENDING',
      });
      expect(minimal.amount, isNull);
      expect(minimal.currency, isNull);
      expect(minimal.clientSecret, isNull);
      expect(minimal.createTime, isNull);
      expect(minimal.latestPaymentAttempt, isNull);
      expect(minimal.availablePaymentMethodTypes, isNull);

      expect(
        () => UqpayPaymentIntent.fromJson(const <String, Object?>{
          'intent_status': 'X',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('payment_intent_id'),
          ),
        ),
      );
      expect(
        () => UqpayPaymentIntent.fromJson(const <String, Object?>{
          'payment_intent_id': 'pi',
          'intent_status': '',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('intent_status'),
          ),
        ),
      );
    });

    test('an unknown intent status decodes without throwing', () {
      final intent = UqpayPaymentIntent.fromJson(const <String, Object?>{
        'payment_intent_id': 'pi_1',
        'intent_status': 'BRAND_NEW',
      });
      expect(intent.status.isUnknown, isTrue);
      expect(intent.status.raw, 'BRAND_NEW');
      expect(intent.status.isSuccess, isFalse);
    });

    test('is lenient about wrong-typed fields', () {
      final intent = UqpayPaymentIntent.fromJson(const <String, Object?>{
        'payment_intent_id': 'pi_1',
        'intent_status': 'SUCCEEDED',
        'amount': 8.98, // a JSON float — not the wire contract; dropped
        'captured_amount': 100, // a JSON int — accepted verbatim
        'currency': 12,
        'client_secret': '',
        'metadata': 'not-a-map',
        'available_payment_method_types': 'card',
        'payment_method': <String, Object?>{'card': <String, Object?>{}},
        'customer': 'nope',
        'next_action': 42,
        'latest_payment_attempt': <String, Object?>{
          'attempt_status': 7,
          'amount': 'abc',
          'failure_code': '',
        },
      });
      expect(intent.amount, isNull);
      expect(intent.capturedAmount!.toWireString(), '100');
      expect(intent.currency, isNull);
      expect(intent.clientSecret, isNull);
      expect(intent.metadata, isNull);
      expect(intent.availablePaymentMethodTypes, isNull);
      expect(intent.paymentMethod, isNull, reason: 'payment_method sans type');
      expect(intent.customer, isNull);
      expect(intent.nextAction, isNull);
      expect(intent.latestPaymentAttempt!.status, isNull);
      expect(intent.latestPaymentAttempt!.amount, isNull);
      expect(intent.latestPaymentAttempt!.failureCode, isNull);
    });

    test('attempt id is read from attempt_id or payment_attempt_id', () {
      expect(
        UqpayPaymentAttempt.fromJson(const {
          'payment_attempt_id': 'pa_1',
        }).attemptId,
        'pa_1',
      );
      expect(
        UqpayPaymentAttempt.fromJson(const {
          'attempt_id': 'a_1',
          'payment_attempt_id': 'pa_1',
        }).attemptId,
        'a_1',
      );
      expect(UqpayPaymentAttempt.fromJson(const {}).attemptId, isNull);
      expect(UqpayPaymentAttempt.fromJson(const {}).isFailed, isFalse);
    });
  });

  group('UqpayNextAction', () {
    test('infers the type when the server omits it', () {
      expect(
        UqpayNextAction.fromJson(const {
          'redirect_to_url': {'url': 'https://x'},
        }).type,
        UqpayNextActionType.redirectToUrl,
      );
      expect(
        UqpayNextAction.fromJson(const {
          'display_qr_code': {'qr_code_url': 'https://x/qr.png'},
        }).type,
        UqpayNextActionType.displayQrCode,
      );
      expect(
        UqpayNextAction.fromJson(const {
          'display_bank_details': {'bank_name': 'B'},
        }).type,
        UqpayNextActionType.displayBankDetails,
      );
      expect(
        UqpayNextAction.fromJson(const {
          'redirect_iframe': {'iframe': '<form method="POST"></form>'},
        }).type,
        UqpayNextActionType.redirectIframe,
      );
      expect(UqpayNextAction.fromJson(const {}).type, isNull);
      expect(UqpayNextAction.fromJson(const {'type': ''}).rawType, isNull);
    });

    test('an explicit type wins over inference, even when unknown', () {
      final action = UqpayNextAction.fromJson(const {
        'type': 'hologram',
        'redirect_to_url': {'url': 'https://x'},
      });
      expect(action.type!.raw, 'hologram');
      expect(action.type!.isUnknown, isTrue);
      expect(action.toJson(), {
        'type': 'hologram',
        'redirect_to_url': {'url': 'https://x'},
      });
    });

    test('display_qr_code carries both raw payload and image URL', () {
      final raw = UqpayDisplayQrCode.fromJson(const {
        'qr_code': '00020101021226580009SG.PAYNOW',
        'qr_code_url': '',
        'expires_at': '2026-08-18T12:10:00Z',
      });
      expect(raw.hasRawPayload, isTrue);
      expect(raw.qrCodeUrl, isNull);
      expect(raw.expiresAt, '2026-08-18T12:10:00Z');

      final url = UqpayDisplayQrCode.fromJson(const {
        'qr_code': 'https://cdn.example/qr.png',
      });
      expect(url.hasRawPayload, isFalse);
      expect(const UqpayDisplayQrCode().hasRawPayload, isFalse);
    });

    test('all leaf models decode with every field absent', () {
      expect(UqpayRedirectToUrl.fromJson(const {}).url, isNull);
      expect(UqpayRedirectToUrl.fromJson(const {}).returnUrl, isNull);
      expect(UqpayDisplayBankDetails.fromJson(const {}).bankName, isNull);
      expect(UqpayDisplayBankDetails.fromJson(const {}).accountNumber, isNull);
      expect(UqpayDisplayBankDetails.fromJson(const {}).routingNumber, isNull);
      expect(UqpayRedirectIframe.fromJson(const {}).iframe, isNull);
      expect(
        UqpayDisplayBankDetails.fromJson(const {
          'bank_name': 'B',
          'account_number': '1',
          'routing_number': '2',
        }).toJson(),
        {'bank_name': 'B', 'account_number': '1', 'routing_number': '2'},
      );
      expect(UqpayRedirectIframe.fromJson(const {'iframe': '<x>'}).toJson(), {
        'iframe': '<x>',
      });
    });
  });

  group('shared leaf models', () {
    test('address, billing, customer, auth data round-trip', () {
      const address = UqpayAddress(
        countryCode: 'SG',
        state: 'SG',
        city: 'Singapore',
        street: '1 Street, #01-01',
        postcode: '018956',
      );
      expect(UqpayAddress.fromJson(address.toJson()), address);

      const billing = UqpayBillingDetails(
        firstName: 'A',
        lastName: 'B',
        email: 'a@b.c',
        phoneNumber: '+65',
        address: address,
      );
      expect(UqpayBillingDetails.fromJson(billing.toJson()), billing);
      expect(billing.toString(), 'UqpayBillingDetails(redacted)');

      const customer = UqpayCustomer(
        firstName: 'A',
        lastName: 'B',
        email: 'a@b.c',
        phoneNumber: '+65',
        description: 'd',
        address: address,
        metadata: {'k': 'v'},
      );
      expect(UqpayCustomer.fromJson(customer.toJson()), customer);

      const auth = UqpayAuthenticationData(
        cvvResult: 'M',
        avsResult: 'Y',
        threeDs: UqpayThreeDsResult(
          threeDsVersion: '2',
          cavv: 'c',
          eci: '05',
          dsTransactionId: 'ds',
          authenticationStatus: 'Y',
          cancellationReason: 'r',
        ),
      );
      expect(UqpayAuthenticationData.fromJson(auth.toJson()), auth);
      expect(UqpayAuthenticationData.fromJson(const {}).threeDs, isNull);

      const threeDs = UqpayThreeDsData(
        returnUrl: 'r',
        acsResponse: 'a',
        deviceDataCollectionRes: 'd',
        dsTransactionId: 'ds',
      );
      expect(UqpayThreeDsData.fromJson(threeDs.toJson()), threeDs);
    });

    test('models are value-equal by content and distinct by type', () {
      const a = UqpayAddress(city: 'X');
      const b = UqpayAddress(city: 'X');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const UqpayAddress(city: 'Y')));
      // Same JSON, different types → not equal.
      expect(
        const UqpayRedirectIframe(),
        isNot(equals(const UqpayDisplayBankDetails())),
      );
      expect(a.toString(), 'UqpayAddress(…)');
    });

    test('UqpayPaymentMethod and its card round-trip through JSON', () {
      const method = UqpayPaymentMethod(
        type: 'card',
        card: UqpayCardPaymentMethod(
          cardName: 'A B',
          maskedCardNumber: '424242******4242',
          network: 'visa',
          billing: UqpayBillingDetails(firstName: 'A'),
          autoCapture: true,
          authorizationType: 'authorization',
          threeDsAction: 'enforce_3ds',
          threeDs: UqpayThreeDsData(dsTransactionId: 'ds'),
        ),
      );
      expect(UqpayPaymentMethod.fromJson(method.toJson()), method);
      expect(method.toJson()['type'], 'card');
      expect(
        (method.toJson()['card']! as Map<String, Object?>)['card_number'],
        '424242******4242',
      );
    });

    test('UqpayPaymentMethod requires a type', () {
      expect(
        () => UqpayPaymentMethod.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        UqpayPaymentMethod.fromJson(const {'type': 'paynow'}).card,
        isNull,
      );
      expect(UqpayCardPaymentMethod.fromJson(const {}).billing, isNull);
    });
  });
}
