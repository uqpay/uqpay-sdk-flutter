// Generates ERROR_CODES.md from the SDK's own source of truth and fails if the
// checked-in file has drifted: the table is generated from the same source
// as the code so it cannot drift.
//
// To regenerate after an intentional change:
//   UPDATE_ERROR_TABLE=1 flutter test test/docs/error_table_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/errors/error_mapper.dart';
import 'package:uqpay_sdk_flutter/src/transport/transport_failure.dart';

/// How each code is produced, and what a merchant should do about it.
/// Keyed by [UqpayErrorCode.raw] so a new constant fails this test loudly
/// rather than silently shipping an undocumented code.
const Map<String, ({String when, String action})> _guidance = {
  'card_declined': (
    when: 'The issuer declined the payment.',
    action: 'Ask for a different card. Do not retry the same card blindly.',
  ),
  'insufficient_funds': (
    when: 'The issuer declined for lack of funds.',
    action: 'Ask for a different card or payment method.',
  ),
  'invalid_payment_method': (
    when: 'The payment details or request were rejected as invalid.',
    action:
        'Check the details you collected, then let the customer re-enter them.',
  ),
  '3ds_failed': (
    when: '3-D Secure authentication failed or was abandoned.',
    action: 'Offer another card, or ask the customer to contact their bank.',
  ),
  'cancelled': (
    when: 'The intent or attempt was cancelled.',
    action: 'Treat as an abandoned checkout; start a new intent to try again.',
  ),
  'authentication_failed': (
    when: 'The auth token was rejected (401/403), even after one refresh.',
    action:
        'Your backend must mint a fresh token. Check credentials and '
        'clock skew.',
  ),
  'invalid_configuration': (
    when: 'The SDK was misconfigured.',
    action:
        'A programming error — fix the configuration. It is also thrown '
        'as an ArgumentError at init.',
  ),
  'network_error': (
    when: 'Socket-level failure: refused, reset, no route, offline.',
    action: 'Retry with the same idempotency key once connectivity returns.',
  ),
  'dns_failure': (
    when:
        'The host name could not be resolved. The request never left '
        'the device.',
    action: 'Safe to retry; no payment was created.',
  ),
  'timeout': (
    when:
        'The request or a poll budget expired. The payment may still be live.',
    action:
        'Never treat as failure. Reconcile the intent before charging again.',
  ),
  'tls_failure': (
    when: 'The TLS handshake failed. The request never left the device.',
    action:
        'Do not retry automatically — the same request fails the same way. '
        'Check the device clock and for interception proxies; the SDK never '
        'accepts a bad certificate. No payment was created.',
  ),
  'server_error': (
    when: 'The API answered 5xx. The outcome is unknown.',
    action: 'Retry with the SAME idempotency key, then reconcile.',
  ),
  'rate_limited': (
    when: 'The API answered 429. The outcome is unknown.',
    action: 'Back off, then retry with the SAME idempotency key.',
  ),
  'malformed_response': (
    when: 'A 2xx body could not be parsed. The request WAS processed.',
    action:
        'Reconcile the intent. Never retry blindly — that risks a '
        'double charge.',
  ),
  'unknown': (
    when:
        'No more specific classification was possible, or the server sent a '
        'code this SDK version does not know — including a server code that '
        'happens to spell an SDK-reserved code such as `timeout` or '
        '`network_error` (the raw value is kept in `serverCode`).',
    action:
        'Show userMessage, log code.raw and traceId for support. Never '
        'report success.',
  ),
};

/// Every input combination [mapFailure] distinguishes, so the "Retryable"
/// column is read from the mapper itself rather than written down by hand.
List<UqpayError> _mapperProbes() {
  final serverCodes = <String>[
    for (final code in UqpayErrorCode.known) code.raw,
    'do_not_honor',
    'some_unrecognised_code',
  ];
  return [
    mapFailure(outcomeDeadlineExceeded: true),
    for (final kind in UqpayTransportFailureKind.values)
      mapFailure(transportFailure: kind),
    mapFailure(malformedResponse: true, httpStatus: 200),
    mapFailure(intentStatus: UqpayIntentStatus.cancelled),
    mapFailure(attemptFailed: true),
    for (final code in serverCodes) mapFailure(attemptFailureCode: code),
    for (final status in const [
      400,
      401,
      402,
      403,
      404,
      409,
      422,
      429,
      500,
    ]) ...[
      mapFailure(httpStatus: status),
      for (final code in serverCodes)
        mapFailure(httpStatus: status, envelopeCode: code),
    ],
    mapFailure(noPaymentMethodAttached: true),
    mapFailure(),
  ];
}

/// "yes" / "no" when every way the mapper produces [code] agrees, "depends"
/// when it does not, and a pointer to `isRetryable` when the code is raised
/// outside the mapper only.
String _retryable(UqpayErrorCode code, List<UqpayError> probes) {
  final values = {
    for (final error in probes)
      if (error.code == code) error.isRetryable,
  };
  if (values.isEmpty) {
    return 'see `isRetryable`';
  }
  if (values.length > 1) {
    return 'depends — read `isRetryable`';
  }
  return values.single ? 'yes' : 'no';
}

String _generate() {
  final probes = _mapperProbes();
  final buffer = StringBuffer()
    ..writeln('<!-- GENERATED FILE — do not edit by hand.')
    ..writeln('     Regenerate with:')
    ..writeln(
      '       UPDATE_ERROR_TABLE=1 flutter test '
      'test/docs/error_table_test.dart',
    )
    ..writeln(
      "     The table below is produced from UqpayErrorCode and the SDK's own",
    )
    ..writeln(
      '     message/retry logic, so it cannot drift from the code. -->',
    )
    ..writeln()
    ..writeln('# Error codes')
    ..writeln()
    ..writeln(
      'Every error the SDK can report, what causes it, whether the *same* '
      'request may',
    )
    ..writeln('be sent again, and what to tell the customer.')
    ..writeln()
    ..writeln(
      '`UqpayErrorCode` is an **open** type. A code this SDK version does not',
    )
    ..writeln(
      "recognise arrives with `isUnknown == true` and the server's string "
      'preserved in',
    )
    ..writeln(
      '`raw` — it never throws and is never reported as success. Always '
      'write '
      'your',
    )
    ..writeln('`switch` with a `default`.')
    ..writeln()
    ..writeln('## Outcome-unknown codes are not failures')
    ..writeln()
    ..writeln(
      '`timeout`, `server_error`, `rate_limited` and `malformed_response` mean '
      'the',
    )
    ..writeln(
      'server **may have taken the payment**. Reconcile the intent before '
      'letting the',
    )
    ..writeln(
      'customer pay again, and reuse the same idempotency key on any retry.',
    )
    ..writeln()
    ..writeln(
      'Retryability is a property of the *occurrence*, not of the code — '
      'read',
    )
    ..writeln(
      '`error.isRetryable` and `error.isOutcomeUnknown` on the error you were '
      'given.',
    )
    ..writeln(
      'The "Retryable" column is read from the SDK\'s error mapper; '
      '"depends" means',
    )
    ..writeln(
      'the mapper flags some occurrences retryable and others not. A few '
      'local failures',
    )
    ..writeln(
      'raised outside the mapper (for example a missing device IP on a card '
      'confirm, or',
    )
    ..writeln(
      'local storage refusing the idempotency pin) set their own flag, so '
      'always read',
    )
    ..writeln(
      '`error.isRetryable` at runtime. The transport table below shows the '
      'concrete',
    )
    ..writeln('mapping for each transport failure.')
    ..writeln()
    ..writeln(
      '| Code | When it happens | Retryable | What you should do | Message '
      'shown to the customer |',
    )
    ..writeln('|---|---|---|---|---|');

  for (final code in UqpayErrorCode.known) {
    final g = _guidance[code.raw];
    if (g == null) {
      throw StateError(
        'UqpayErrorCode "${code.raw}" has no entry in _guidance. Add one so '
        'the '
        'published error table documents every code the SDK can emit.',
      );
    }
    buffer.writeln(
      '| `${code.raw}` '
      '| ${g.when} '
      '| ${_retryable(code, probes)} '
      '| ${g.action} '
      '| ${defaultUserMessage(code)} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Transport failures')
    ..writeln()
    ..writeln(
      'Each distinct transport failure maps to its own code, never to',
    )
    ..writeln('`unknown`:')
    ..writeln()
    ..writeln(
      '| Transport failure | Code | Retryable | Payment may have been taken |',
    )
    ..writeln('|---|---|---|---|');
  for (final kind in UqpayTransportFailureKind.values) {
    final error = mapFailure(transportFailure: kind);
    buffer.writeln(
      '| `${kind.name}` | `${error.code.raw}` | '
      '${error.isRetryable ? 'yes' : 'no'} | '
      '${error.isOutcomeUnknown ? '**maybe — reconcile**' : 'no'} |',
    );
  }

  buffer
    ..writeln()
    ..writeln(
      'On web the browser does not expose DNS or TLS failures separately: a '
      'failed',
    )
    ..writeln(
      '`fetch` is opaque, so both surface as `network_error` (the '
      '`socket` row).',
    )
    ..writeln()
    ..writeln('## Every error carries')
    ..writeln()
    ..writeln('| Field | Purpose |')
    ..writeln('|---|---|')
    ..writeln('| `code` | Stable typed code from the table above. |')
    ..writeln(
      '| `userMessage` | Safe to display as-is. No jargon, no JSON, no server '
      'codes. |',
    )
    ..writeln(
      "| `developerMessage` | For your logs. May contain the server's own "
      'wording. |',
    )
    ..writeln('| `isRetryable` | Whether the same request may be sent again. |')
    ..writeln(
      '| `isOutcomeUnknown` | Whether the payment may have been taken anyway. '
      '|',
    )
    ..writeln(
      '| `serverCode` | The raw server code, preserved even when unrecognised. '
      '|',
    )
    ..writeln(
      '| `traceId` / `responseId` | From `x-trace-id` / `x-response-id`. Quote '
      'these to support. |',
    )
    ..writeln('| `httpStatus` | The HTTP status, when there was one. |');

  return buffer.toString();
}

void main() {
  test('ERROR_CODES.md matches the code', () {
    final generated = _generate();
    final file = File('ERROR_CODES.md');

    if (Platform.environment['UPDATE_ERROR_TABLE'] == '1') {
      file.writeAsStringSync(generated);
      return;
    }

    expect(
      file.existsSync(),
      isTrue,
      reason:
          'ERROR_CODES.md is missing. Regenerate it with '
          'UPDATE_ERROR_TABLE=1 flutter test test/docs/error_table_test.dart',
    );
    expect(
      file.readAsStringSync(),
      generated,
      reason:
          'ERROR_CODES.md has drifted from the code. Regenerate it with '
          'UPDATE_ERROR_TABLE=1 flutter test test/docs/error_table_test.dart',
    );
  });
}
