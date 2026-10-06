import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error_code.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_intent_status.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

/// The customer-facing message for a code: plain language, no
/// jargon, no server codes, and — for declines — what to do next.
///
/// This is the single English catalogue; the localisation layer (P4) will
/// key off [UqpayErrorCode.raw] to override it.
String defaultUserMessage(UqpayErrorCode code) {
  if (code == UqpayErrorCode.cardDeclined) {
    return 'Your card was declined. Please try a different card or contact '
        'your bank.';
  }
  if (code == UqpayErrorCode.insufficientFunds) {
    return 'There are not enough funds available. Please try a different '
        'card or payment method.';
  }
  if (code == UqpayErrorCode.invalidPaymentMethod) {
    return 'These payment details could not be used. Please check them and '
        'try again.';
  }
  if (code == UqpayErrorCode.threeDsFailed) {
    return 'Card authentication failed. Please try another card or contact '
        'your bank.';
  }
  if (code == UqpayErrorCode.cancelled) {
    return 'The payment was cancelled.';
  }
  if (code == UqpayErrorCode.authenticationFailed ||
      code == UqpayErrorCode.invalidConfiguration) {
    return 'The payment could not be started. Please try again later.';
  }
  if (code == UqpayErrorCode.networkError ||
      code == UqpayErrorCode.dnsFailure ||
      code == UqpayErrorCode.tlsFailure) {
    return 'We could not reach the payment service. Please check your '
        'connection and try again.';
  }
  if (code == UqpayErrorCode.timeout ||
      code == UqpayErrorCode.serverError ||
      code == UqpayErrorCode.rateLimited ||
      code == UqpayErrorCode.malformedResponse) {
    return "We couldn't confirm whether your payment went through. Please "
        "wait a moment; do not pay again until you've checked your order.";
  }
  return 'The payment could not be completed. Please try again.';
}

/// **The** mapping from a failure — however it surfaced — to a [UqpayError].
/// Every code path in the SDK, for every payment method, goes
/// through this function; there is no second mapper.
///
/// Inputs are all optional; supply whichever the failure produced. Precedence,
/// highest first:
///
/// 0. [outcomeDeadlineExceeded] — the SDK's own poll budget ran out while
///    the intent was still non-terminal: a timeout whose outcome is unknown.
/// 1. [transportFailure] — DNS / socket / timeout / TLS, each distinct.
/// 2. [malformedResponse] — a 2xx whose body could not be parsed: the request
///    **was** processed, so the outcome is unknown and it is not retried.
/// 3. [intentStatus] cancelled — cancellation wins over any attempt code.
/// 4. [attemptFailureCode] (or [attemptFailed] with no code) — a declined
///    attempt inside a 2xx / intent read.
/// 5. [httpStatus] with the error envelope [envelopeCode]: a known
///    code maps directly; 401/403 → authentication failed; 429 / 5xx →
///    outcome unknown and retryable with the same key; an unrecognised code is
///    preserved as an unknown [UqpayErrorCode] with `raw` intact;
///    with no code at all the status alone decides.
/// 6. [noPaymentMethodAttached] — a 2xx confirm response or an intent read
///    whose status is `REQUIRES_PAYMENT_METHOD` with **no** attempt at all:
///    the server accepted the call but attached nothing.
/// 7. Otherwise [UqpayErrorCode.unknown].
///
/// The result's `userMessage` is always drawn from the SDK's catalogue, never
/// from the server's `message`; the server text goes into
/// `developerMessage` and `serverMessage`. Never throws.
UqpayError mapFailure({
  bool outcomeDeadlineExceeded = false,
  UqpayTransportFailureKind? transportFailure,
  bool malformedResponse = false,
  UqpayIntentStatus? intentStatus,
  String? attemptFailureCode,
  String? attemptFailureMessage,
  bool attemptFailed = false,
  int? httpStatus,
  String? envelopeCode,
  String? envelopeType,
  String? envelopeMessage,
  String? traceId,
  String? responseId,
  bool noPaymentMethodAttached = false,
}) {
  UqpayError build(
    UqpayErrorCode code, {
    required String developerMessage,
    required bool isRetryable,
    bool isOutcomeUnknown = false,
    String? serverCode,
    String? serverMessage,
  }) => UqpayError(
    code: code,
    developerMessage: developerMessage,
    userMessage: defaultUserMessage(code),
    isRetryable: isRetryable,
    isOutcomeUnknown: isOutcomeUnknown,
    httpStatus: httpStatus,
    serverCode: serverCode,
    serverMessage: serverMessage,
    traceId: traceId,
    responseId: responseId,
  );

  // 0. The SDK's own outcome deadline.
  if (outcomeDeadlineExceeded) {
    return build(
      UqpayErrorCode.timeout,
      developerMessage:
          'The intent was still not terminal when the outcome deadline was '
          'reached; the payment may still complete — reconcile later.',
      isRetryable: true,
      isOutcomeUnknown: true,
    );
  }

  // 1. Transport.
  switch (transportFailure) {
    case UqpayTransportFailureKind.dns:
      return build(
        UqpayErrorCode.dnsFailure,
        developerMessage: 'The API host name could not be resolved.',
        isRetryable: true,
      );
    case UqpayTransportFailureKind.socket:
      return build(
        UqpayErrorCode.networkError,
        developerMessage:
            'The connection to the API failed; the request may or may not '
            'have reached the server.',
        isRetryable: true,
        isOutcomeUnknown: true,
      );
    case UqpayTransportFailureKind.timeout:
      return build(
        UqpayErrorCode.timeout,
        developerMessage:
            'The request timed out; the request may have reached the server.',
        isRetryable: true,
        isOutcomeUnknown: true,
      );
    case UqpayTransportFailureKind.tls:
      return build(
        UqpayErrorCode.tlsFailure,
        developerMessage:
            'The TLS handshake with the API failed; check the device clock '
            'and network (the SDK never accepts a bad certificate).',
        isRetryable: false,
      );
    case null:
      break;
  }

  // 2. Malformed 2xx.
  if (malformedResponse) {
    return build(
      UqpayErrorCode.malformedResponse,
      developerMessage:
          'The API returned HTTP ${httpStatus ?? '2xx'} but the body could not '
          'be decoded; the request was processed — reconcile the intent.',
      isRetryable: false,
      isOutcomeUnknown: true,
    );
  }

  // 3. Cancellation wins.
  if (intentStatus != null && intentStatus.isCancelled) {
    return build(
      UqpayErrorCode.cancelled,
      developerMessage: 'The payment intent is ${intentStatus.raw}.',
      isRetryable: false,
      serverCode: _nonEmpty(attemptFailureCode),
      serverMessage: _nonEmpty(attemptFailureMessage),
    );
  }

  // 4. Attempt failure code.
  final failureCode = _nonEmpty(attemptFailureCode);
  if (failureCode != null || attemptFailed) {
    final serverMessage = _nonEmpty(attemptFailureMessage);
    final code = switch (failureCode) {
      null => UqpayErrorCode.cardDeclined,
      '3ds_failed' => UqpayErrorCode.threeDsFailed,
      'insufficient_funds' => UqpayErrorCode.insufficientFunds,
      'do_not_honor' || 'card_declined' => UqpayErrorCode.cardDeclined,
      'invalid_payment_method' => UqpayErrorCode.invalidPaymentMethod,
      _ => _serverCodeOrUnknown(failureCode),
    };
    return build(
      code,
      developerMessage:
          'The payment attempt failed'
          '${failureCode == null ? '' : ' with failure_code "$failureCode"'}'
          '${serverMessage == null ? '' : ': $serverMessage'}.',
      isRetryable: false,
      serverCode: failureCode,
      serverMessage: serverMessage,
    );
  }

  // 5. HTTP status + error envelope.
  if (httpStatus != null) {
    final code = _nonEmpty(envelopeCode);
    final serverMessage = _nonEmpty(envelopeMessage);
    final type = _nonEmpty(envelopeType);
    final detail =
        'HTTP $httpStatus'
        '${type == null ? '' : ' $type'}'
        '${code == null ? '' : ' code "$code"'}'
        '${serverMessage == null ? '' : ': $serverMessage'}';

    if (httpStatus == 429 || httpStatus >= 500) {
      return build(
        httpStatus == 429
            ? UqpayErrorCode.rateLimited
            : UqpayErrorCode.serverError,
        developerMessage:
            '$detail. Outcome unknown — retry with the same idempotency key, '
            'then reconcile.',
        isRetryable: true,
        isOutcomeUnknown: true,
        serverCode: code,
        serverMessage: serverMessage,
      );
    }
    if (httpStatus == 401 || httpStatus == 403) {
      return build(
        UqpayErrorCode.authenticationFailed,
        developerMessage:
            '$detail. The auth token was rejected (after one refresh); check '
            'the token provider and environment.',
        isRetryable: false,
        serverCode: code,
        serverMessage: serverMessage,
      );
    }

    final mapped = switch (code) {
      'card_declined' || 'do_not_honor' => UqpayErrorCode.cardDeclined,
      'insufficient_funds' => UqpayErrorCode.insufficientFunds,
      'invalid_payment_method' => UqpayErrorCode.invalidPaymentMethod,
      '3ds_failed' => UqpayErrorCode.threeDsFailed,
      // No code at all: the status alone decides.
      null => switch (httpStatus) {
        402 => UqpayErrorCode.cardDeclined,
        400 || 404 || 422 => UqpayErrorCode.invalidPaymentMethod,
        _ => UqpayErrorCode.unknown,
      },
      // Unrecognised: preserve verbatim.
      _ => _serverCodeOrUnknown(code),
    };
    return build(
      mapped,
      developerMessage: '$detail.',
      isRetryable: false,
      serverCode: code,
      serverMessage: serverMessage,
    );
  }

  // 6. A confirm that attached nothing.
  if (noPaymentMethodAttached) {
    return build(
      UqpayErrorCode.invalidPaymentMethod,
      developerMessage:
          'The intent is REQUIRES_PAYMENT_METHOD with no payment attempt: the '
          'confirm did not attach a payment method.',
      isRetryable: false,
    );
  }

  // 7. Nothing to go on.
  return build(
    UqpayErrorCode.unknown,
    developerMessage: 'The payment failed for an unclassified reason.',
    isRetryable: false,
    serverCode: _nonEmpty(envelopeCode),
    serverMessage: _nonEmpty(envelopeMessage),
  );
}

String? _nonEmpty(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  final clean = redactCardLikeDigits(value);
  return clean.isEmpty ? null : clean;
}

/// Replaces any run of 13–19 digits — with or without the spaces or dashes a
/// card number is commonly written with — by `[digits]`, so a server, proxy
/// or WAF that echoes a PAN back in an error message never reaches a
/// merchant's logs through `developerMessage` / `serverMessage`.
/// Shorter runs (amounts, timestamps, trace ids) are left alone.
String redactCardLikeDigits(String value) {
  // Normalise Unicode decimal digits (Arabic-Indic, full-width, …) to ASCII
  // and drop HTML tags, so `<td>4242</td>` or `٤٢٤٢` cannot slip past.
  final normalised = value
      .replaceAll(RegExp('<[^>]{1,64}>'), ' ')
      .replaceAllMapped(RegExp(r'\p{Nd}', unicode: true), (m) {
        final ch = m.group(0)!;
        final code = ch.runes.first;
        if (code >= 0x30 && code <= 0x39) {
          return ch;
        }
        // Every Unicode Nd block is a contiguous run of ten digits.
        return String.fromCharCode(0x30 + _digitValue(code));
      });
  return normalised.replaceAll(
    RegExp(r'(?:\d[ \t\u00A0.\-_/]?){12,18}\d'),
    '[digits]',
  );
}

int _digitValue(int rune) {
  // Nd runs start at a code point whose value is the digit zero; a run is
  // contiguous and aligned, so the digit is the offset within its run.
  const zeros = <int>[
    0x0660,
    0x06F0,
    0x07C0,
    0x0966,
    0x09E6,
    0x0A66,
    0x0AE6,
    0x0B66,
    0x0BE6,
    0x0C66,
    0x0CE6,
    0x0D66,
    0x0DE6,
    0x0E50,
    0x0ED0,
    0x0F20,
    0x1040,
    0x1090,
    0x17E0,
    0x1810,
    0x1946,
    0x19D0,
    0x1A80,
    0x1A90,
    0x1B50,
    0x1BB0,
    0x1C40,
    0x1C50,
    0xA620,
    0xA8D0,
    0xA900,
    0xA9D0,
    0xA9F0,
    0xAA50,
    0xABF0,
    0xFF10,
  ];
  for (final zero in zeros) {
    if (rune >= zero && rune <= zero + 9) {
      return rune - zero;
    }
  }
  return 0;
}

/// Server codes that happen to spell an SDK-reserved transport or lifecycle
/// code must not be mistaken for that condition: a decline whose
/// `failure_code` is `"timeout"` is still a decline, not an outcome-unknown
/// timeout. They surface as [UqpayErrorCode.unknown] with the raw value in
/// `serverCode`.
UqpayErrorCode _serverCodeOrUnknown(String code) {
  const reserved = <String>{
    'timeout',
    'server_error',
    'rate_limited',
    'malformed_response',
    'network_error',
    'dns_failure',
    'tls_failure',
    'authentication_failed',
    'invalid_configuration',
    'cancelled',
  };
  return reserved.contains(code)
      ? UqpayErrorCode.unknown
      : UqpayErrorCode.fromRaw(code);
}
