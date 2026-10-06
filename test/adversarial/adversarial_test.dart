import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/core/canonical_json.dart'
    show encodeCanonicalJson;
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

void main() {
  group('UqpayAmount adversarial', () {
    test('parses valid amounts and round-trips exactly', () {
      final cases = <String>[
        '0',
        '1',
        '100',
        '8.98',
        '0.50',
        '0.05',
        '1000.000',
        '1.500',
        '0.001',
        '-1',
        '-0.50',
        '-1234.567',
      ];

      for (final wire in cases) {
        final amount = UqpayAmount.parse(wire);
        expect(amount.toWireString(), wire, reason: 'Round-trip for $wire');
        expect(amount.toString(), wire);
      }
    });

    test('rejects malformed inputs', () {
      final bad = <String>[
        '',
        ' 8.98',
        '8.98 ',
        '8.',
        '.5',
        '07.50',
        '1e2',
        r'$8.98',
        '+8.98',
        '1,234.50',
        '8.98USD',
      ];

      for (final input in bad) {
        expect(
          () => UqpayAmount.parse(input),
          throwsA(isA<FormatException>()),
          reason: 'Should reject: $input',
        );
        expect(
          UqpayAmount.tryParse(input),
          isNull,
          reason: 'tryParse should return null for: $input',
        );
      }
    });

    test('formats with intl and never rounds', () {
      final amount = UqpayAmount.parse('1.500');
      final formatted = amount.format(currencyCode: 'BHD', locale: 'en_US');
      // Should show 3 digits, never "1.5"
      expect(formatted, contains('1.500'));
    });

    test('equality across scales', () {
      expect(
        UqpayAmount.parse('1.5'),
        UqpayAmount.parse('1.50'),
      );
      expect(
        UqpayAmount.parse('100'),
        UqpayAmount.parse('100.000'),
      );
    });

    test('negative zero equals zero', () {
      expect(
        UqpayAmount.parse('-0.00'),
        UqpayAmount.parse('0'),
      );
    });

    test('compareTo works numerically', () {
      final neg = UqpayAmount.parse('-1');
      final zero = UqpayAmount.parse('0');
      final pos = UqpayAmount.parse('1');

      expect(neg.compareTo(zero), lessThan(0));
      expect(zero.compareTo(pos), lessThan(0));
      expect(pos.compareTo(zero), greaterThan(0));
    });

    test('hash consistent across scales', () {
      expect(
        UqpayAmount.parse('1.5').hashCode,
        UqpayAmount.parse('1.50').hashCode,
      );
    });
  });

  group('Models fromJson adversarial', () {
    test('UqpayPaymentIntent with missing optional fields', () {
      final json = <String, Object?>{
        'payment_intent_id': 'pi_123',
        'intent_status': 'SUCCEEDED',
      };
      final intent = UqpayPaymentIntent.fromJson(json);
      expect(intent.id, 'pi_123');
      expect(intent.status.raw, 'SUCCEEDED');
      expect(intent.amount, isNull);
      expect(intent.currency, isNull);
    });

    test('throws FormatException when required fields missing', () {
      expect(
        () => UqpayPaymentIntent.fromJson(const <String, Object?>{
          'intent_status': 'SUCCEEDED',
        }),
        throwsA(isA<FormatException>()),
        reason: 'Missing payment_intent_id',
      );

      expect(
        () => UqpayPaymentIntent.fromJson(const <String, Object?>{
          'payment_intent_id': 'pi_123',
        }),
        throwsA(isA<FormatException>()),
        reason: 'Missing intent_status',
      );
    });

    test('amount as string is preserved exactly', () {
      const json = <String, Object?>{
        'payment_intent_id': 'pi_123',
        'intent_status': 'SUCCEEDED',
        'amount': '1.500',
      };
      final intent = UqpayPaymentIntent.fromJson(json);
      expect(intent.amount?.toWireString(), '1.500');
    });

    test('ignores unknown extra keys', () {
      final json = <String, Object?>{
        'payment_intent_id': 'pi_123',
        'intent_status': 'SUCCEEDED',
        'unknown_field': 'ignored',
        'another': 123,
      };
      final intent = UqpayPaymentIntent.fromJson(json);
      expect(intent.id, 'pi_123');
    });

    test('round-trip toJson → fromJson equality', () {
      final original = UqpayPaymentIntent.fromJson(const <String, Object?>{
        'payment_intent_id': 'pi_123',
        'intent_status': 'SUCCEEDED',
        'amount': '8.98',
        'currency': 'USD',
      });

      final json = original.toJson();
      final recovered = UqpayPaymentIntent.fromJson(json);

      expect(recovered.id, original.id);
      expect(recovered.status, original.status);
      expect(recovered.amount, original.amount);
      expect(recovered.currency, original.currency);
    });
  });

  group('Status types adversarial', () {
    test('all known statuses are recognized', () {
      for (final status in UqpayIntentStatus.known) {
        final recovered = UqpayIntentStatus.fromRaw(status.raw);
        expect(recovered, status);
        expect(recovered.isUnknown, isFalse);
      }
    });

    test('unknown status is preserved and fails open', () {
      final unknown = UqpayIntentStatus.fromRaw('FUTURE_STATUS_V99');
      expect(unknown.raw, 'FUTURE_STATUS_V99');
      expect(unknown.isUnknown, isTrue);
      expect(unknown.shouldPoll, isTrue, reason: 'Fail open: keep polling');
    });

    test('CANCELED (one L) is recognized as cancelled', () {
      expect(
        UqpayIntentStatus.fromRaw('CANCELED').isCancelled,
        isTrue,
      );
    });

    test('case sensitivity: lowercase is unknown', () {
      final lower = UqpayIntentStatus.fromRaw('succeeded');
      expect(lower.isUnknown, isTrue);
      expect(lower.isSuccess, isFalse);
    });

    test('REQUIRES_CAPTURE.isSuccess is true', () {
      expect(UqpayIntentStatus.requiresCapture.isSuccess, isTrue);
      expect(UqpayIntentStatus.requiresCapture.isTerminal, isFalse);
    });

    test('PENDING.isTerminal is false', () {
      expect(UqpayIntentStatus.pending.isTerminal, isFalse);
      expect(UqpayIntentStatus.pending.shouldPoll, isTrue);
    });
  });

  group('Error code adversarial', () {
    test('all known error codes compare equal', () {
      final known = [
        ('card_declined', UqpayErrorCode.cardDeclined),
        ('insufficient_funds', UqpayErrorCode.insufficientFunds),
        ('3ds_failed', UqpayErrorCode.threeDsFailed),
        ('unknown', UqpayErrorCode.unknown),
      ];

      for (final (raw, constant) in known) {
        expect(UqpayErrorCode.fromRaw(raw), constant);
      }
    });

    test('unknown code preserves raw value', () {
      final unknown = UqpayErrorCode.fromRaw('future_code_999');
      expect(unknown.raw, 'future_code_999');
      expect(unknown.isUnknown, isTrue);
    });

    test('hash is consistent', () {
      expect(
        UqpayErrorCode.cardDeclined.hashCode,
        UqpayErrorCode.fromRaw('card_declined').hashCode,
      );
    });
  });

  group('Error mapper', () {
    test('transport failures map distinctly', () {
      final dns = mapFailure(
        transportFailure: UqpayTransportFailureKind.dns,
      );
      expect(dns.code, UqpayErrorCode.dnsFailure);
      expect(dns.isRetryable, isTrue);

      final socket = mapFailure(
        transportFailure: UqpayTransportFailureKind.socket,
      );
      expect(socket.code, UqpayErrorCode.networkError);
      expect(socket.isRetryable, isTrue);
      expect(socket.isOutcomeUnknown, isTrue);

      final timeout = mapFailure(
        transportFailure: UqpayTransportFailureKind.timeout,
      );
      expect(timeout.code, UqpayErrorCode.timeout);
      expect(timeout.isRetryable, isTrue);

      final tls = mapFailure(
        transportFailure: UqpayTransportFailureKind.tls,
      );
      expect(tls.code, UqpayErrorCode.tlsFailure);
      expect(tls.isRetryable, isFalse);
    });

    test('malformed 2xx response is outcome unknown', () {
      final error = mapFailure(malformedResponse: true, httpStatus: 200);
      expect(error.code, UqpayErrorCode.malformedResponse);
      expect(error.isOutcomeUnknown, isTrue);
      expect(error.isRetryable, isFalse);
    });

    test('cancelled intent status wins precedence', () {
      final error = mapFailure(
        intentStatus: UqpayIntentStatus.cancelled,
        attemptFailureCode: 'card_declined',
      );
      expect(error.code, UqpayErrorCode.cancelled);
    });

    test('attempt failure codes are recognized', () {
      final threeds = mapFailure(
        attemptFailureCode: '3ds_failed',
        attemptFailed: true,
      );
      expect(threeds.code, UqpayErrorCode.threeDsFailed);

      final insufficient = mapFailure(
        attemptFailureCode: 'insufficient_funds',
        attemptFailed: true,
      );
      expect(insufficient.code, UqpayErrorCode.insufficientFunds);

      final unknown = mapFailure(
        attemptFailureCode: 'unknown_reason_xyz',
        attemptFailed: true,
      );
      expect(unknown.code.isUnknown, isTrue);
      expect(unknown.code.raw, 'unknown_reason_xyz');
    });

    test('HTTP 429 is retryable outcome unknown', () {
      final error = mapFailure(httpStatus: 429);
      expect(error.code, UqpayErrorCode.rateLimited);
      expect(error.isRetryable, isTrue);
      expect(error.isOutcomeUnknown, isTrue);
    });

    test('HTTP 5xx is retryable outcome unknown', () {
      for (final status in [500, 502, 503]) {
        final error = mapFailure(httpStatus: status);
        expect(
          error.code,
          UqpayErrorCode.serverError,
          reason: 'Status $status',
        );
        expect(error.isRetryable, isTrue);
        expect(error.isOutcomeUnknown, isTrue);
      }
    });

    test('HTTP 401/403 is authentication failed', () {
      final error401 = mapFailure(httpStatus: 401);
      expect(error401.code, UqpayErrorCode.authenticationFailed);
      expect(error401.isRetryable, isFalse);

      final error403 = mapFailure(httpStatus: 403);
      expect(error403.code, UqpayErrorCode.authenticationFailed);
    });

    test('unknown status code preserved', () {
      final error = mapFailure(
        httpStatus: 400,
        envelopeCode: 'new_decline_reason_v999',
      );
      expect(error.code.isUnknown, isTrue);
      expect(error.code.raw, 'new_decline_reason_v999');
    });
  });

  group('Error userMessage safety', () {
    test('userMessage never contains raw codes', () {
      final error = mapFailure(
        httpStatus: 400,
        envelopeCode: 'invalid_payment_method',
      );
      expect(error.userMessage, isNotEmpty);
      expect(error.userMessage, isNot(contains('invalid_payment_method')));
    });

    test('userMessage never contains braces', () {
      for (final code in UqpayErrorCode.known) {
        final error = mapFailure(
          attemptFailureCode: code.raw,
          attemptFailed: true,
        );
        expect(error.userMessage, isNotEmpty);
        expect(error.userMessage, isNot(contains('{')));
        expect(error.userMessage, isNot(contains('}')));
      }
    });

    test('userMessage never contains Exception or stack', () {
      final error = mapFailure(
        transportFailure: UqpayTransportFailureKind.socket,
      );
      expect(error.userMessage, isNot(contains('Exception')));
      expect(error.userMessage, isNot(contains('trace')));
      expect(error.userMessage, isNot(contains('Stack')));
    });
  });

  group('Error trace propagation', () {
    test('traceId and responseId are preserved', () {
      final error = mapFailure(
        httpStatus: 500,
        traceId: 'trace-123',
        responseId: 'resp-456',
      );
      expect(error.traceId, 'trace-123');
      expect(error.responseId, 'resp-456');
    });
  });

  group('Canonical JSON', () {
    test('key order independence', () {
      final obj1 = <String, Object?>{
        'a': 1,
        'b': 2,
        'c': 3,
      };

      final obj2 = <String, Object?>{
        'c': 3,
        'a': 1,
        'b': 2,
      };

      expect(encodeCanonicalJson(obj1), encodeCanonicalJson(obj2));
    });

    test('produces sorted key JSON', () {
      final obj = <String, Object?>{
        'z': 1,
        'a': 2,
        'm': 3,
      };

      final encoded = encodeCanonicalJson(obj);
      final aIdx = encoded.indexOf('"a"');
      final mIdx = encoded.indexOf('"m"');
      final zIdx = encoded.indexOf('"z"');

      expect(aIdx < mIdx, isTrue);
      expect(mIdx < zIdx, isTrue);
    });

    test('nested objects sorted', () {
      final obj = <String, Object?>{
        'outer': <String, Object?>{
          'z': 1,
          'a': 2,
        },
      };

      final encoded = encodeCanonicalJson(obj);
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      final reencoded = encodeCanonicalJson(decoded);

      expect(encoded, reencoded);
    });

    test('round-trip byte-identical', () {
      final original = <String, Object?>{
        'status': 'SUCCEEDED',
        'amount': '8.98',
        'nested': <String, Object?>{
          'key': 'value',
        },
      };

      final encoded1 = encodeCanonicalJson(original);
      final decoded = jsonDecode(encoded1) as Map<String, Object?>;
      final encoded2 = encodeCanonicalJson(decoded);

      expect(encoded1, encoded2);
    });

    test('numbers preserved as numbers not strings', () {
      final obj = <String, Object?>{
        'count': 42,
        'price': '8.98', // string on purpose
      };

      final encoded = encodeCanonicalJson(obj);
      expect(encoded, contains('42'));
      expect(encoded, contains('"8.98"'));
      expect(encoded, isNot(contains('"42"')));
    });

    test('rejects double values', () {
      expect(
        () => encodeCanonicalJson(<String, Object?>{'pi': 3.14159}),
        throwsA(isA<ArgumentError>()),
        reason: 'No doubles allowed on the wire',
      );
    });
  });

  group('Redaction', () {
    test('card details toString does not leak PAN', () {
      final card = UqpayCardDetails(
        cardName: 'Test',
        cardNumber: '4242424242424242',
        expiryMonth: '12',
        expiryYear: '2025',
        cvc: '123',
        network: 'visa',
        billing: const UqpayBillingDetails(),
      );

      final str = card.toString();
      expect(str, isNot(contains('4242424242424242')));
      expect(str, isNot(contains('123')));
    });

    test('confirm request toString does not leak PAN or CVC', () {
      final request = UqpayConfirmRequest(
        paymentMethod: UqpayConfirmPaymentMethod.card(
          UqpayCardDetails(
            cardName: 'Ada Lovelace',
            cardNumber: '4242424242424242',
            expiryMonth: '09',
            expiryYear: '2030',
            cvc: '737',
            network: 'visa',
            billing: const UqpayBillingDetails(),
          ),
        ),
        browserInfo: const UqpayBrowserInfo(
          browser: UqpayBrowserDetails(userAgent: 'test'),
          deviceId: 'device-1',
          language: 'en',
          mobile: UqpayMobileDetails(
            deviceModel: 'iPhone',
            osType: 'IOS',
            osVersion: '17',
          ),
          screenHeight: 800,
          screenWidth: 400,
          timezone: '0',
        ),
      );

      final str = request.toString();
      expect(str, isNot(contains('4242424242424242')));
      expect(str, isNot(contains('737')));
    });

    test('error userMessage never contains test PAN or CVC', () {
      final error = mapFailure(
        attemptFailureCode: 'card_declined',
        attemptFailed: true,
      );
      expect(error.userMessage, isNot(contains('4242')));
      expect(error.userMessage, isNot(contains('737')));
    });
  });
}
