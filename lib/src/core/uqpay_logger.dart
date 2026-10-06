import 'dart:developer' as developer;

/// The merchant-facing diagnostic log sink (opt-in via
/// `UqpaySdk.init(loggingEnabled: true)`).
///
/// What it logs: HTTP method, path, status code, trace id, intent id, flow
/// phase transitions and the class name of an unexpected exception — the
/// same contract as the Android SDK's `loggingEnabled`. What it never
/// receives: a request or response body, a card number, CVC, expiry,
/// cardholder name, auth token or API key. Call sites pass only the fields
/// listed above; there is no "log this object" entry point, so the
/// redaction test can hold the line at the type level.
///
/// When disabled every call is a no-op. When enabled, lines go to the
/// merchant's `logHandler` if one was supplied, else to `dart:developer`
/// under the name `uqpay` (visible in DevTools and `flutter run` output).
/// A throwing handler is swallowed: diagnostics can never take a payment
/// down.
class UqpayLogger {
  /// Creates a logger. A disabled logger ignores [handler].
  factory UqpayLogger({
    required bool enabled,
    void Function(String line)? handler,
  }) => enabled ? UqpayLogger._(enabled: true, handler: handler) : disabled;

  const UqpayLogger._({required this.enabled, this.handler});

  /// The logger used when logging is off: every call is a no-op.
  static const UqpayLogger disabled = UqpayLogger._(enabled: false);

  /// Whether lines are emitted at all.
  final bool enabled;

  /// Where lines go when set; `dart:developer` otherwise.
  final void Function(String line)? handler;

  /// Emits one line. [message] must already be free of secrets — callers
  /// compose it from identifiers and status words only.
  void log(String message) {
    if (!enabled) {
      return;
    }
    final line = '[uqpay] $message';
    final sink = handler;
    if (sink == null) {
      developer.log(line, name: 'uqpay');
      return;
    }
    try {
      sink(line);
    } on Object {
      // A merchant's log handler must never break a payment.
    }
  }

  /// An HTTP line: `POST /api/v2/payment_intents/PI…/confirm -> 200
  /// trace=…`. Query strings are dropped; bodies are never passed.
  void http({
    required String method,
    required Uri url,
    required int status,
    String? traceId,
  }) => log(
    '$method ${url.path} -> $status'
    '${traceId == null ? '' : ' trace=$traceId'}',
  );
}
