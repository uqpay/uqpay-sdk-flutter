import 'dart:async';
import 'dart:convert';

import 'package:uqpay_sdk_flutter/headless.dart';
import 'package:uqpay_sdk_flutter/src/core/uqpay_clock.dart';
import 'package:uqpay_sdk_flutter/src/flow/polling_policy.dart';
import 'package:uqpay_sdk_flutter/src/idempotency/key_value_store.dart';
import 'package:uqpay_sdk_flutter/src/transport/uqpay_http_client.dart';

/// A fully controllable clock. `elapsed` and `now` only move when the test
/// says so; `delay` completes immediately after advancing `elapsed`, and every
/// requested delay is recorded.
class FakeClock extends UqpayClock {
  FakeClock({DateTime? now})
    : _now = now ?? DateTime.utc(2026, 8, 18, 12),
      _elapsed = Duration.zero;

  DateTime _now;
  Duration _elapsed;
  final List<Duration> delays = <Duration>[];

  @override
  Duration get elapsed => _elapsed;

  @override
  DateTime now() => _now;

  /// Advances both the monotonic and the wall clock.
  void advance(Duration by) {
    _elapsed += by;
    _now = _now.add(by);
  }

  /// Advances only the wall clock (simulates a device clock change / a
  /// process restart with a fresh stopwatch).
  void advanceWallClockOnly(Duration by) {
    _now = _now.add(by);
  }

  @override
  Future<void> delay(Duration duration) async {
    delays.add(duration);
    _elapsed += duration;
    _now = _now.add(duration);
  }
}

/// A scripted [UqpayHttpClient]. Each call pops the next handler; a handler
/// returns a response or throws whatever the test wants the transport to
/// throw. Every request is recorded for header assertions.
class FakeHttpClient implements UqpayHttpClient {
  final List<FutureOr<UqpayHttpResponse> Function(UqpayHttpRequest)> _handlers =
      [];
  final List<UqpayHttpRequest> requests = <UqpayHttpRequest>[];
  bool closed = false;

  /// Queues a canned response.
  void enqueue(UqpayHttpResponse response) => _handlers.add((_) => response);

  /// Queues a handler.
  void enqueueHandler(
    FutureOr<UqpayHttpResponse> Function(UqpayHttpRequest) handler,
  ) => _handlers.add(handler);

  /// Queues a thrown error.
  void enqueueError(Object error) =>
      _handlers.add((_) => Future<UqpayHttpResponse>.error(error));

  @override
  Future<UqpayHttpResponse> send(UqpayHttpRequest request) async {
    requests.add(request);
    if (_handlers.isEmpty) {
      throw StateError('FakeHttpClient: no handler queued for $request');
    }
    return _handlers.removeAt(0)(request);
  }

  @override
  void close() => closed = true;
}

/// Builds a JSON response with the standard trace headers.
UqpayHttpResponse jsonResponse(
  int status,
  Object? body, {
  String? traceId = 'trace-1',
  String? responseId = 'resp-1',
}) => UqpayHttpResponse(
  statusCode: status,
  headers: <String, String>{
    'Content-Type': 'application/json',
    'X-Trace-Id': ?traceId,
    'X-Response-Id': ?responseId,
  },
  body: body is String ? body : jsonEncode(body),
);

/// A representative intent object, as the API returns it.
Map<String, Object?> intentJson({
  String status = 'REQUIRES_PAYMENT_METHOD',
  String amount = '8.98',
  Map<String, Object?>? attempt,
  Map<String, Object?>? nextAction,
}) => <String, Object?>{
  'payment_intent_id': 'pi_123',
  'intent_status': status,
  'amount': amount,
  'currency': 'SGD',
  'captured_amount': '0.00',
  'client_secret': 'cs_secret',
  'merchant_order_id': 'order-1',
  'description': 'Coffee',
  'metadata': <String, Object?>{'k': 'v', 'n': 1},
  'return_url': 'myapp://payment',
  'create_time': '2026-08-18T12:00:00Z',
  'update_time': '2026-08-18T12:00:01Z',
  'available_payment_method_types': <Object?>['card', 'paynow', 7],
  'latest_payment_attempt': ?attempt,
  'next_action': ?nextAction,
};

/// The Stripe test PAN — never a real card.
const String testPan = '4242424242424242';

/// The CVC used alongside [testPan] in tests.
const String testCvc = '737';

/// A complete card confirm request.
UqpayConfirmRequest cardConfirmRequest({
  String cardNumber = testPan,
  String cvc = testCvc,
  String cardName = 'Ada Lovelace',
}) => UqpayConfirmRequest(
  paymentMethod: UqpayConfirmPaymentMethod.card(
    UqpayCardDetails(
      cardName: cardName,
      cardNumber: cardNumber,
      expiryMonth: '09',
      expiryYear: '2030',
      cvc: cvc,
      network: 'visa',
      billing: const UqpayBillingDetails(
        firstName: 'Ada',
        lastName: 'Lovelace',
        email: 'ada@example.com',
        address: UqpayAddress(
          countryCode: 'SG',
          city: 'Singapore',
          street: '1 Test Street, #01-01',
          postcode: '018956',
        ),
      ),
    ),
  ),
  browserInfo: browserInfo(),
  ipAddress: '10.0.0.2',
);

/// A frozen device snapshot.
UqpayBrowserInfo browserInfo() => const UqpayBrowserInfo(
  browser: UqpayBrowserDetails(
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X)',
  ),
  deviceId: 'device-1',
  language: 'en-SG',
  mobile: UqpayMobileDetails(
    deviceModel: 'iPhone',
    osType: 'IOS',
    osVersion: 'iOS 17.2',
  ),
  screenHeight: 852,
  screenWidth: 393,
  timezone: '8',
);

/// An [UqpaySdk] wired with a token provider that hands out [tokens] in
/// order (the last one repeats).
UqpaySdk sdkWithTokens(
  List<String> tokens, {
  UqpayEnvironment environment = UqpayEnvironment.sandbox,
  String? clientId,
  String? onBehalfOf,
  List<int>? providerCalls,
}) {
  var index = 0;
  return UqpaySdk.init(
    environment: environment,
    clientId: clientId,
    onBehalfOf: onBehalfOf,
    tokenProvider: () async {
      providerCalls?.add(index);
      final token = tokens[index < tokens.length ? index : tokens.length - 1];
      index++;
      return UqpayAuthToken(value: token);
    },
  );
}

/// A pending timer inside a [ManualClock].
class _PendingTimer {
  _PendingTimer(this.due, this.completer);
  final Duration due;
  final Completer<void> completer;
}

/// A clock whose time moves **only** when the test calls [advance]. Delays
/// stay pending until their due time is reached, so a test can observe a
/// flow *between* polls, drive pause/resume while a wait is outstanding, and
/// count live timers for the leak test.
///
/// [pendingTimers] is the number of delays started and neither elapsed nor
/// cancelled; a finished flow must leave it at zero.
class ManualClock extends UqpayClock {
  ManualClock({DateTime? now})
    : _now = now ?? DateTime.utc(2026, 8, 18, 12),
      _elapsed = Duration.zero;

  DateTime _now;
  Duration _elapsed;
  final List<_PendingTimer> _timers = <_PendingTimer>[];

  /// Every delay requested, in order, whether or not it elapsed.
  final List<Duration> requestedDelays = <Duration>[];

  /// Delays that were cancelled before elapsing.
  int cancelledDelays = 0;

  /// Live (started, not elapsed, not cancelled) timers.
  int get pendingTimers => _timers.length;

  @override
  Duration get elapsed => _elapsed;

  @override
  DateTime now() => _now;

  @override
  Future<void> delay(Duration duration) => startDelay(duration).future;

  @override
  UqpayDelay startDelay(Duration duration) {
    requestedDelays.add(duration);
    final timer = _PendingTimer(_elapsed + duration, Completer<void>());
    _timers.add(timer);
    return UqpayDelay(timer.completer.future, () {
      if (_timers.remove(timer)) {
        cancelledDelays++;
      }
      if (!timer.completer.isCompleted) {
        timer.completer.complete();
      }
    });
  }

  /// Moves time forward by [by], firing every timer that falls due (in due
  /// order). Timers scheduled *while* firing (from microtasks) are not
  /// reached in this call — pump the event queue and advance again.
  void advance(Duration by) {
    final target = _elapsed + by;
    _now = _now.add(by);
    while (true) {
      _PendingTimer? next;
      for (final t in _timers) {
        if (t.due <= target && (next == null || t.due < next.due)) {
          next = t;
        }
      }
      if (next == null) {
        break;
      }
      _timers.remove(next);
      _elapsed = next.due;
      next.completer.complete();
    }
    _elapsed = target;
  }

  /// Advances only the wall clock.
  void advanceWallClockOnly(Duration by) {
    _now = _now.add(by);
  }
}

/// A [UqpayPayments] wired entirely with fakes: scripted HTTP, an in-memory
/// pin store and an injectable clock. Default polling has **no jitter** so
/// schedules are exact; pass `policy` to override.
class PaymentsHarness {
  PaymentsHarness({
    UqpayClock? clock,
    PollingPolicy? policy,
    UqpaySdk? sdk,
    List<String> tokens = const <String>['tok'],
  }) : clock = clock ?? FakeClock() {
    payments = UqpayPayments.withDependencies(
      sdk: sdk ?? sdkWithTokens(tokens),
      httpClient: http,
      clock: this.clock,
      storage: storage,
      pollingPolicy: policy ?? PollingPolicy(jitter: 0),
    );
  }

  final FakeHttpClient http = FakeHttpClient();
  final InMemoryKeyValueStore storage = InMemoryKeyValueStore();
  final UqpayClock clock;
  late final UqpayPayments payments;

  /// The requests sent so far with [method].
  List<UqpayHttpRequest> sent(String method) =>
      http.requests.where((r) => r.method == method).toList();

  /// Confirm requests sent so far.
  List<UqpayHttpRequest> get confirms =>
      http.requests.where((r) => r.url.path.endsWith('/confirm')).toList();

  /// Intent reads sent so far.
  List<UqpayHttpRequest> get reads => sent('GET');
}

/// A wallet (PayNow QR) confirm request.
UqpayConfirmRequest walletConfirmRequest() => UqpayConfirmRequest(
  paymentMethod: UqpayConfirmPaymentMethod.wallet(
    'paynow',
    const UqpayWalletDetails(),
  ),
  browserInfo: browserInfo(),
  ipAddress: '10.0.0.2',
);

/// A failed attempt object with [failureCode].
Map<String, Object?> failedAttempt(String failureCode, {String message = ''}) =>
    <String, Object?>{
      'attempt_id': 'pa_1',
      'attempt_status': 'FAILED',
      'failure_code': failureCode,
      'failure_message': message,
    };

/// A `display_qr_code` next action.
Map<String, Object?> qrNextAction() => <String, Object?>{
  'type': 'display_qr_code',
  'display_qr_code': <String, Object?>{
    'qr_code': '00020101021226...',
    'expires_at': '2026-08-18T12:10:00Z',
  },
};

/// A `redirect_to_url` next action.
Map<String, Object?> redirectNextAction() => <String, Object?>{
  'type': 'redirect_to_url',
  'redirect_to_url': <String, Object?>{
    'url': 'https://acs.example/challenge',
    'return_url': 'myapp://payment',
  },
};
