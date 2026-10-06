import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

void main() {
  /// User messages carry no jargon, JSON, codes or stack traces.
  void expectSafeUserMessage(UqpayError error) {
    final message = error.userMessage;
    expect(message, isNotEmpty);
    expect(message, isNot(contains('{')));
    expect(message, isNot(contains('_')), reason: 'no snake_case codes');
    expect(message, isNot(contains('HTTP')));
    expect(message.toLowerCase(), isNot(contains('exception')));
    expect(message.toLowerCase(), isNot(contains('null')));
    expect(message.toLowerCase(), isNot(contains('json')));
    if (error.serverCode != null) {
      expect(message, isNot(contains(error.serverCode)));
    }
    if (error.serverMessage != null && error.serverMessage!.isNotEmpty) {
      expect(message, isNot(contains(error.serverMessage)));
    }
  }

  group('mapFailure — error envelope on 4xx/5xx', () {
    // (status, code, expected)
    const table = <(int, String?, UqpayErrorCode)>[
      (402, 'card_declined', UqpayErrorCode.cardDeclined),
      (402, 'do_not_honor', UqpayErrorCode.cardDeclined),
      (402, 'insufficient_funds', UqpayErrorCode.insufficientFunds),
      (400, 'invalid_payment_method', UqpayErrorCode.invalidPaymentMethod),
      (400, '3ds_failed', UqpayErrorCode.threeDsFailed),
      // Known codes map regardless of status.
      (400, 'card_declined', UqpayErrorCode.cardDeclined),
      (422, 'insufficient_funds', UqpayErrorCode.insufficientFunds),
      // No code: status decides.
      (401, null, UqpayErrorCode.authenticationFailed),
      (403, null, UqpayErrorCode.authenticationFailed),
      (402, null, UqpayErrorCode.cardDeclined),
      (400, null, UqpayErrorCode.invalidPaymentMethod),
      (404, null, UqpayErrorCode.invalidPaymentMethod),
      (422, null, UqpayErrorCode.invalidPaymentMethod),
      (409, null, UqpayErrorCode.unknown),
      (418, '', UqpayErrorCode.unknown),
      // Auth statuses win over any code.
      (401, 'card_declined', UqpayErrorCode.authenticationFailed),
      (403, 'weird', UqpayErrorCode.authenticationFailed),
      // 429 / 5xx: outcome unknown, regardless of code.
      (429, null, UqpayErrorCode.rateLimited),
      (429, 'card_declined', UqpayErrorCode.rateLimited),
      (500, null, UqpayErrorCode.serverError),
      (502, 'system_error', UqpayErrorCode.serverError),
      (503, '', UqpayErrorCode.serverError),
      (599, null, UqpayErrorCode.serverError),
    ];

    for (final (status, code, expected) in table) {
      test('HTTP $status code=${code ?? '<none>'} → ${expected.raw}', () {
        final error = mapFailure(
          httpStatus: status,
          envelopeCode: code,
          envelopeType: 'invalid_request_error',
          envelopeMessage: 'language is invalid',
          traceId: 't-1',
          responseId: 'r-1',
        );
        expect(error.code, expected);
        expect(error.httpStatus, status);
        expect(error.traceId, 't-1');
        expect(error.responseId, 'r-1');
        expect(error.serverCode, code == null || code.isEmpty ? null : code);
        expect(error.serverMessage, 'language is invalid');
        expect(error.developerMessage, contains('HTTP $status'));
        expect(error.developerMessage, contains('language is invalid'));
        final outcomeUnknown = status == 429 || status >= 500;
        expect(error.isRetryable, outcomeUnknown);
        expect(error.isOutcomeUnknown, outcomeUnknown);
        expectSafeUserMessage(error);
      });
    }

    test('an unrecognised code is preserved verbatim as unknown', () {
      final error = mapFailure(
        httpStatus: 400,
        envelopeCode: 'card_expired_new',
        envelopeMessage: '',
      );
      expect(error.code.isUnknown, isTrue);
      expect(error.isUnknown, isTrue);
      expect(error.code.raw, 'card_expired_new');
      expect(error.serverCode, 'card_expired_new');
      expect(error.serverMessage, isNull, reason: 'empty → null');
      expect(error.isRetryable, isFalse);
      expect(error.isOutcomeUnknown, isFalse);
      expect(error.developerMessage, contains('code "card_expired_new"'));
      expectSafeUserMessage(error);
      // And it never masquerades as success in any status type.
      expect(UqpayIntentStatus.fromRaw(error.code.raw).isSuccess, isFalse);
    });

    test('an unrecognised code on 402 is still unknown, not a decline', () {
      final error = mapFailure(httpStatus: 402, envelopeCode: 'brand_new');
      expect(error.code.raw, 'brand_new');
      expect(error.code.isUnknown, isTrue);
      expect(error.httpStatus, 402);
    });
  });

  group('mapFailure — attempt failure_code', () {
    const table = <(String?, UqpayErrorCode)>[
      ('3ds_failed', UqpayErrorCode.threeDsFailed),
      ('insufficient_funds', UqpayErrorCode.insufficientFunds),
      ('do_not_honor', UqpayErrorCode.cardDeclined),
      ('card_declined', UqpayErrorCode.cardDeclined),
      ('invalid_payment_method', UqpayErrorCode.invalidPaymentMethod),
      (null, UqpayErrorCode.cardDeclined),
      ('', UqpayErrorCode.cardDeclined),
    ];

    for (final (code, expected) in table) {
      test('failure_code=${code ?? '<null>'} → ${expected.raw}', () {
        final error = mapFailure(
          attemptFailed: true,
          attemptFailureCode: code,
          attemptFailureMessage: '',
          intentStatus: UqpayIntentStatus.requiresPaymentMethod,
        );
        expect(error.code, expected);
        expect(error.isRetryable, isFalse);
        expect(error.isOutcomeUnknown, isFalse);
        expect(error.httpStatus, isNull);
        expect(error.serverCode, code == null || code.isEmpty ? null : code);
        expect(error.serverMessage, isNull);
        expectSafeUserMessage(error);
      });
    }

    test('an unrecognised failure_code is preserved as unknown', () {
      final error = mapFailure(
        attemptFailureCode: 'issuer_unavailable_v9',
        attemptFailureMessage: 'Issuer said no',
      );
      expect(error.code.isUnknown, isTrue);
      expect(error.code.raw, 'issuer_unavailable_v9');
      expect(error.serverCode, 'issuer_unavailable_v9');
      expect(error.serverMessage, 'Issuer said no');
      expect(error.developerMessage, contains('Issuer said no'));
      expectSafeUserMessage(error);
    });

    test('a failure_code without attemptFailed still maps', () {
      expect(
        mapFailure(attemptFailureCode: '3ds_failed').code,
        UqpayErrorCode.threeDsFailed,
      );
    });

    test('cancellation wins over the attempt code', () {
      for (final raw in ['CANCELLED', 'CANCELED']) {
        final error = mapFailure(
          intentStatus: UqpayIntentStatus.fromRaw(raw),
          attemptFailed: true,
          attemptFailureCode: '3ds_failed',
          attemptFailureMessage: 'x',
          httpStatus: 200,
        );
        expect(error.code, UqpayErrorCode.cancelled);
        expect(error.serverCode, '3ds_failed');
        expect(error.serverMessage, 'x');
        expect(error.developerMessage, contains(raw));
        expect(error.isRetryable, isFalse);
        expectSafeUserMessage(error);
      }
    });

    test('a non-cancelled intent status alone does not classify', () {
      final error = mapFailure(intentStatus: UqpayIntentStatus.failed);
      expect(error.code, UqpayErrorCode.unknown);
    });
  });

  group('mapFailure — transport and decode failures', () {
    test('each transport failure kind maps to a distinct code', () {
      final codes = <UqpayErrorCode>{};
      for (final kind in UqpayTransportFailureKind.values) {
        final error = mapFailure(transportFailure: kind);
        codes.add(error.code);
        expect(error.httpStatus, isNull);
        expectSafeUserMessage(error);
        expect(error.code.isUnknown, isFalse, reason: 'never generic unknown');
      }
      expect(codes, hasLength(UqpayTransportFailureKind.values.length));
    });

    test('DNS: retryable, outcome known', () {
      final e = mapFailure(transportFailure: UqpayTransportFailureKind.dns);
      expect(e.code, UqpayErrorCode.dnsFailure);
      expect(e.isRetryable, isTrue);
      expect(e.isOutcomeUnknown, isFalse);
    });

    test('socket: retryable, outcome unknown', () {
      final e = mapFailure(transportFailure: UqpayTransportFailureKind.socket);
      expect(e.code, UqpayErrorCode.networkError);
      expect(e.isRetryable, isTrue);
      expect(e.isOutcomeUnknown, isTrue);
    });

    test('timeout: retryable, outcome unknown', () {
      final e = mapFailure(transportFailure: UqpayTransportFailureKind.timeout);
      expect(e.code, UqpayErrorCode.timeout);
      expect(e.isRetryable, isTrue);
      expect(e.isOutcomeUnknown, isTrue);
    });

    test('TLS: not retryable, outcome known', () {
      final e = mapFailure(transportFailure: UqpayTransportFailureKind.tls);
      expect(e.code, UqpayErrorCode.tlsFailure);
      expect(e.isRetryable, isFalse);
      expect(e.isOutcomeUnknown, isFalse);
    });

    test('transport failure wins over everything else', () {
      final e = mapFailure(
        transportFailure: UqpayTransportFailureKind.timeout,
        malformedResponse: true,
        httpStatus: 500,
        intentStatus: UqpayIntentStatus.cancelled,
        attemptFailureCode: '3ds_failed',
      );
      expect(e.code, UqpayErrorCode.timeout);
    });

    test('malformed 2xx: not retryable, outcome unknown', () {
      final e = mapFailure(
        malformedResponse: true,
        httpStatus: 200,
        traceId: 't',
      );
      expect(e.code, UqpayErrorCode.malformedResponse);
      expect(e.isRetryable, isFalse);
      expect(e.isOutcomeUnknown, isTrue);
      expect(e.httpStatus, 200);
      expect(e.traceId, 't');
      expect(e.developerMessage, contains('HTTP 200'));
      expectSafeUserMessage(e);
      expect(
        mapFailure(malformedResponse: true).developerMessage,
        contains('2xx'),
      );
    });

    test('malformed wins over cancellation/attempt/envelope', () {
      final e = mapFailure(
        malformedResponse: true,
        intentStatus: UqpayIntentStatus.cancelled,
        attemptFailureCode: '3ds_failed',
        httpStatus: 200,
      );
      expect(e.code, UqpayErrorCode.malformedResponse);
    });

    test('the transport codes are distinct from 5xx and malformed', () {
      final all = <UqpayErrorCode>{
        mapFailure(transportFailure: UqpayTransportFailureKind.dns).code,
        mapFailure(transportFailure: UqpayTransportFailureKind.socket).code,
        mapFailure(transportFailure: UqpayTransportFailureKind.timeout).code,
        mapFailure(transportFailure: UqpayTransportFailureKind.tls).code,
        mapFailure(httpStatus: 500).code,
        mapFailure(httpStatus: 429).code,
        mapFailure(malformedResponse: true).code,
      };
      expect(all, hasLength(7));
      expect(all, isNot(contains(UqpayErrorCode.unknown)));
    });
  });

  group('mapFailure — nothing to go on', () {
    test('returns unknown, never throws', () {
      final e = mapFailure();
      expect(e.code, UqpayErrorCode.unknown);
      expect(e.isUnknown, isTrue);
      expect(e.isRetryable, isFalse);
      expect(e.isOutcomeUnknown, isFalse);
      expect(e.serverCode, isNull);
      expectSafeUserMessage(e);
      final withCode = mapFailure(envelopeCode: 'x', envelopeMessage: 'y');
      expect(withCode.code, UqpayErrorCode.unknown);
      expect(withCode.serverCode, 'x');
      expect(withCode.serverMessage, 'y');
    });
  });

  group('defaultUserMessage catalogue', () {
    test(
      'every known code has a safe message; unknown codes get the generic',
      () {
        for (final code in UqpayErrorCode.known) {
          final message = defaultUserMessage(code);
          expect(message, isNotEmpty);
          expect(message, isNot(contains('_')));
          expect(message, isNot(contains('3ds')));
        }
        expect(
          defaultUserMessage(UqpayErrorCode.fromRaw('never_seen')),
          defaultUserMessage(UqpayErrorCode.unknown),
        );
        // Declines say what to do next.
        expect(
          defaultUserMessage(UqpayErrorCode.cardDeclined),
          contains('try'),
        );
        expect(
          defaultUserMessage(UqpayErrorCode.insufficientFunds),
          contains('try'),
        );
        expect(
          defaultUserMessage(UqpayErrorCode.threeDsFailed),
          contains('bank'),
        );
      },
    );
  });

  group('UqpayError value semantics', () {
    test('equality, hash, copyWith and redacted toString', () {
      const a = UqpayError(
        code: UqpayErrorCode.timeout,
        developerMessage: 'dev',
        userMessage: 'user',
        isRetryable: true,
        isOutcomeUnknown: true,
        httpStatus: 504,
        serverCode: 'c',
        serverMessage: 'm',
        traceId: 't',
        responseId: 'r',
      );
      const b = UqpayError(
        code: UqpayErrorCode.timeout,
        developerMessage: 'dev',
        userMessage: 'user',
        isRetryable: true,
        isOutcomeUnknown: true,
        httpStatus: 504,
        serverCode: 'c',
        serverMessage: 'm',
        traceId: 't',
        responseId: 'r',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(traceId: 'other')));
      final copy = a.copyWith(
        httpStatus: 1,
        traceId: 'T',
        responseId: 'R',
        isRetryable: false,
        isOutcomeUnknown: false,
      );
      expect(copy.httpStatus, 1);
      expect(copy.traceId, 'T');
      expect(copy.responseId, 'R');
      expect(copy.isRetryable, isFalse);
      expect(copy.isOutcomeUnknown, isFalse);
      expect(copy.code, a.code);
      expect(copy.serverCode, 'c');
      expect(a.copyWith(), a);
      expect(
        a.toString(),
        'UqpayError(code: timeout, httpStatus: 504, retryable: true, '
        'outcomeUnknown: true, traceId: t)',
      );
      expect(a.toString(), isNot(contains('dev')));
      expect(a.toString(), isNot(contains('user')));
    });
  });

  group('mapFailure — flow-level inputs', () {
    test('outcomeDeadlineExceeded → timeout, retryable, outcome unknown', () {
      final error = mapFailure(outcomeDeadlineExceeded: true);
      expect(error.code, UqpayErrorCode.timeout);
      expect(error.isRetryable, isTrue);
      expect(error.isOutcomeUnknown, isTrue);
      expect(error.httpStatus, isNull);
    });

    test('noPaymentMethodAttached → invalidPaymentMethod, not retryable', () {
      final error = mapFailure(
        intentStatus: UqpayIntentStatus.requiresPaymentMethod,
        noPaymentMethodAttached: true,
      );
      expect(error.code, UqpayErrorCode.invalidPaymentMethod);
      expect(error.isRetryable, isFalse);
      expect(error.isOutcomeUnknown, isFalse);
      expect(error.developerMessage, contains('no payment attempt'));
    });

    test('a transport failure outranks the deadline flag', () {
      final error = mapFailure(
        transportFailure: UqpayTransportFailureKind.dns,
        noPaymentMethodAttached: true,
      );
      expect(error.code, UqpayErrorCode.dnsFailure);
    });
  });
}
