import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_next_action.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';

/// Where a payment flow currently is.
///
/// An **open value type** wrapping a `String`, deliberately not an enum or a
/// sealed class: the SDK may add phases in a minor release (for example when
/// a new payment method needs one) without breaking a merchant's `switch`.
/// Compare against the constants; treat an [isUnknown] phase as "still
/// working". The set of phases is documented here and in the CHANGELOG.
@immutable
class UqpayPaymentPhase {
  const UqpayPaymentPhase._(this.raw);

  /// Wraps a raw phase. Never throws.
  factory UqpayPaymentPhase.fromRaw(String raw) => UqpayPaymentPhase._(raw);

  /// Reading the intent before sending anything (terminal-intent guard).
  static const UqpayPaymentPhase preparing = UqpayPaymentPhase._('preparing');

  /// The confirm request is in flight.
  static const UqpayPaymentPhase confirming = UqpayPaymentPhase._('confirming');

  /// A confirm response was lost; the SDK is replaying the same request with
  /// the same idempotency key (3 s / 6 s / 10 s).
  static const UqpayPaymentPhase retrying = UqpayPaymentPhase._('retrying');

  /// The server asks the customer to do something —
  /// [UqpayPaymentStatus.nextAction] says what (3-D Secure, QR scan,
  /// redirect). The SDK keeps polling the intent meanwhile.
  static const UqpayPaymentPhase awaitingCustomerAction = UqpayPaymentPhase._(
    'awaiting_customer_action',
  );

  /// The intent is `PENDING`/`PROCESSING` (or an unknown non-terminal status)
  /// and the SDK is polling for the outcome.
  static const UqpayPaymentPhase awaitingOutcome = UqpayPaymentPhase._(
    'awaiting_outcome',
  );

  /// The flow is paused (`UqpayPaymentFlow.pause`); no request will be sent
  /// until `resume`, which starts with one immediate reconcile.
  static const UqpayPaymentPhase paused = UqpayPaymentPhase._('paused');

  /// The flow has produced its result; the status stream closes after this.
  static const UqpayPaymentPhase finished = UqpayPaymentPhase._('finished');

  /// Every phase this version of the SDK emits.
  static const List<UqpayPaymentPhase> known = <UqpayPaymentPhase>[
    preparing,
    confirming,
    retrying,
    awaitingCustomerAction,
    awaitingOutcome,
    paused,
    finished,
  ];

  /// The phase string, e.g. `confirming`.
  final String raw;

  /// Whether this version of the SDK does not define [raw].
  bool get isUnknown => !known.contains(this);

  @override
  bool operator ==(Object other) =>
      other is UqpayPaymentPhase && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'UqpayPaymentPhase($raw)';
}

/// One progress event on `UqpayPaymentFlow.status`.
///
/// Carries the [phase] and the most recent [intent] the SDK has read, so a UI
/// can show the customer what is happening (and a 3-D Secure / QR layer can
/// react to [nextAction]) without polling itself. The stream is closed as
/// soon as the flow's result is delivered.
@immutable
class UqpayPaymentStatus {
  /// Creates a status event.
  const UqpayPaymentStatus({
    required this.intentId,
    required this.phase,
    this.intent,
    this.pollCount = 0,
  });

  /// The intent being paid.
  final String intentId;

  /// The current phase.
  final UqpayPaymentPhase phase;

  /// The intent as last read from the server, or `null` before the first
  /// successful read.
  final UqpayPaymentIntent? intent;

  /// How many status polls the flow has sent so far.
  final int pollCount;

  /// The customer action the server currently asks for, if any.
  UqpayNextAction? get nextAction => intent?.nextAction;

  @override
  bool operator ==(Object other) =>
      other is UqpayPaymentStatus &&
      other.intentId == intentId &&
      other.phase == phase &&
      other.intent == intent &&
      other.pollCount == pollCount;

  @override
  int get hashCode => Object.hash(intentId, phase, intent, pollCount);

  @override
  String toString() =>
      'UqpayPaymentStatus(intentId: $intentId, phase: ${phase.raw}, '
      'intentStatus: ${intent?.status.raw}, pollCount: $pollCount)';
}
