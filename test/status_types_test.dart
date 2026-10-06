import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';

void main() {
  group('UqpayIntentStatus', () {
    // (raw, terminal, success, poll, unknown)
    const table = <(String, bool, bool, bool, bool)>[
      ('REQUIRES_PAYMENT_METHOD', false, false, false, false),
      ('REQUIRES_CUSTOMER_ACTION', false, false, true, false),
      ('REQUIRES_CAPTURE', false, true, false, false),
      ('PENDING', false, false, true, false),
      ('PROCESSING', false, false, true, false),
      ('SUCCEEDED', true, true, false, false),
      ('CANCELLED', true, false, false, false),
      ('CANCELED', true, false, false, false),
      ('FAILED', true, false, false, false),
      ('SOMETHING_NEW', false, false, true, true),
      ('', false, false, true, true),
    ];

    for (final (raw, terminal, success, poll, unknown) in table) {
      test('"$raw": terminal=$terminal success=$success poll=$poll', () {
        final status = UqpayIntentStatus.fromRaw(raw);
        expect(status.raw, raw);
        expect(status.isTerminal, terminal);
        expect(status.isSuccess, success);
        expect(status.shouldPoll, poll);
        expect(status.isUnknown, unknown);
        expect(status.toString(), 'UqpayIntentStatus($raw)');
      });
    }

    test('constants compare equal to decoded values and hash alike', () {
      expect(
        UqpayIntentStatus.fromRaw('SUCCEEDED'),
        UqpayIntentStatus.succeeded,
      );
      expect(
        UqpayIntentStatus.fromRaw('SUCCEEDED').hashCode,
        UqpayIntentStatus.succeeded.hashCode,
      );
      expect(UqpayIntentStatus.known, hasLength(8));
      expect(UqpayIntentStatus.fromRaw('CANCELED').isCancelled, isTrue);
      expect(
        UqpayIntentStatus.fromRaw('CANCELED'),
        isNot(UqpayIntentStatus.cancelled),
      );
    });

    test('REQUIRES_CAPTURE is success-equivalent, PENDING is not terminal', () {
      // Regressions: REQUIRES_CAPTURE counts as success, PENDING keeps
      // polling.
      expect(UqpayIntentStatus.requiresCapture.isSuccess, isTrue);
      expect(UqpayIntentStatus.requiresCapture.isTerminal, isFalse);
      expect(UqpayIntentStatus.pending.isTerminal, isFalse);
      expect(UqpayIntentStatus.pending.shouldPoll, isTrue);
    });

    test('an unknown status is never a success', () {
      for (final raw in ['SUCCESS', 'succeeded', 'PAID', 'OK']) {
        expect(UqpayIntentStatus.fromRaw(raw).isSuccess, isFalse, reason: raw);
      }
    });
  });

  group('UqpayAttemptStatus', () {
    // (raw, terminal, success)
    const table = <(String, bool, bool)>[
      ('INITIATED', false, false),
      ('AUTHENTICATION_REDIRECTED', false, false),
      ('PENDING_AUTHORIZATION', false, false),
      ('AUTHORIZED', false, true),
      ('CAPTURE_REQUESTED', false, true),
      ('SETTLED', true, true),
      ('SUCCEEDED', true, true),
      ('CANCELLED', true, false),
      ('EXPIRED', true, false),
      ('FAILED', true, false),
      ('NEW_THING', false, false),
    ];

    for (final (raw, terminal, success) in table) {
      test('"$raw": terminal=$terminal success=$success', () {
        final status = UqpayAttemptStatus.fromRaw(raw);
        expect(status.raw, raw);
        expect(status.isTerminal, terminal);
        expect(status.isSuccess, success);
        expect(status.isUnknown, !UqpayAttemptStatus.known.contains(status));
        expect(status.toString(), 'UqpayAttemptStatus($raw)');
      });
    }

    test('constants compare equal to decoded values', () {
      expect(UqpayAttemptStatus.fromRaw('FAILED'), UqpayAttemptStatus.failed);
      expect(
        UqpayAttemptStatus.fromRaw('FAILED').hashCode,
        UqpayAttemptStatus.failed.hashCode,
      );
      expect(UqpayAttemptStatus.known, hasLength(10));
      expect(UqpayAttemptStatus.fromRaw('NEW_THING').isUnknown, isTrue);
    });
  });

  group('UqpayNextActionType', () {
    test('known and unknown values', () {
      expect(
        UqpayNextActionType.fromRaw('redirect_to_url'),
        UqpayNextActionType.redirectToUrl,
      );
      expect(UqpayNextActionType.fromRaw('redirect_to_url').isUnknown, isFalse);
      expect(UqpayNextActionType.fromRaw('hologram').isUnknown, isTrue);
      expect(UqpayNextActionType.fromRaw('hologram').raw, 'hologram');
      expect(
        UqpayNextActionType.fromRaw('hologram').hashCode,
        'hologram'.hashCode,
      );
      expect(
        UqpayNextActionType.displayQrCode.toString(),
        'UqpayNextActionType(display_qr_code)',
      );
      expect(UqpayNextActionType.known, hasLength(4));
    });
  });

  group('UqpayErrorCode', () {
    test(
      'an unrecognised code round-trips with raw preserved and isUnknown',
      () {
        final code = UqpayErrorCode.fromRaw('brand_new_server_code');
        expect(code.isUnknown, isTrue);
        expect(code.raw, 'brand_new_server_code');
        expect(code, UqpayErrorCode.fromRaw('brand_new_server_code'));
        expect(code, isNot(UqpayErrorCode.unknown));
        expect(code.toString(), 'UqpayErrorCode(brand_new_server_code)');
      },
    );

    test('known codes are not unknown, except `unknown` itself', () {
      for (final code in UqpayErrorCode.known) {
        expect(
          code.isUnknown,
          code == UqpayErrorCode.unknown,
          reason: code.raw,
        );
        expect(UqpayErrorCode.fromRaw(code.raw), code);
        expect(UqpayErrorCode.fromRaw(code.raw).hashCode, code.hashCode);
      }
      expect(UqpayErrorCode.threeDsFailed.raw, '3ds_failed');
    });
  });
}
