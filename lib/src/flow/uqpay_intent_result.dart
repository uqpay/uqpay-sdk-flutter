import 'package:flutter/foundation.dart';
import 'package:uqpay_sdk_flutter/src/errors/uqpay_error.dart';
import 'package:uqpay_sdk_flutter/src/models/uqpay_payment_intent.dart';

/// The outcome of reading an intent from the server
/// (`UqpayPayments.retrieveIntent`).
///
/// Sealed with exactly two cases so callers switch exhaustively; a read that
/// fails is **returned** as [UqpayIntentUnavailable], never thrown.
/// Frozen for the 1.x line.
@immutable
sealed class UqpayIntentResult {
  const UqpayIntentResult();
}

/// The intent was read successfully.
final class UqpayIntentRetrieved extends UqpayIntentResult {
  /// Creates a retrieved result.
  const UqpayIntentRetrieved(this.intent);

  /// The intent as the server returned it.
  final UqpayPaymentIntent intent;

  @override
  String toString() => 'UqpayIntentRetrieved(${intent.id})';
}

/// The intent could not be read: transport failure, authentication failure,
/// 4xx (for example an id that does not exist in this environment), 5xx or
/// an undecodable body. [error] says which.
final class UqpayIntentUnavailable extends UqpayIntentResult {
  /// Creates an unavailable result.
  const UqpayIntentUnavailable(this.error);

  /// What went wrong.
  final UqpayError error;

  @override
  String toString() => 'UqpayIntentUnavailable(${error.code.raw})';
}
