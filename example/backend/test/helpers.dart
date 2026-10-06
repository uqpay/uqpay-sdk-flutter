import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uqpay_reference_backend/uqpay_reference_backend.dart';

const testClientId = 'client_test_abcd1234';
const testApiKey = 'sk_test_not_a_real_key_wxyz';

Map<String, String> baseEnv({Map<String, String> extra = const {}}) => {
  'UQPAY_ENVIRONMENT': 'sandbox',
  'UQPAY_CLIENT_ID': testClientId,
  'UQPAY_API_KEY': testApiKey,
  ...extra,
};

/// A controllable stand-in for the UQPAY API.
class FakeUpstream {
  FakeUpstream();

  final List<http.Request> requests = [];
  int tokenIssues = 0;

  /// Token to return from the next issue call(s).
  String nextToken = 'tok_first_0001';

  /// If set, the token endpoint's `expired_at` (epoch seconds, or a string
  /// to exercise tolerant parsing).
  Object? expiredAt;

  /// When non-null, token issuance waits on this before responding, so a
  /// test can pile up concurrent callers.
  Completer<void>? tokenGate;

  /// Non-200 status for the token endpoint (error envelope body).
  int? tokenStatus;

  /// Statuses to return for intent calls, consumed in order; then 200.
  final List<int> intentStatuses = [];

  Map<String, String> intentHeaders = const {'x-trace-id': 'trace-abc-123'};

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/api/v1/connect/token') {
      tokenIssues++;
      final gate = tokenGate;
      if (gate != null) await gate.future;
      if (tokenStatus != null) {
        return http.Response(
          jsonEncode({
            'code': 'invalid_api_key',
            'type': 'unauthorized_error',
            'message': 'api key rejected',
          }),
          tokenStatus!,
        );
      }
      return http.Response(
        jsonEncode({
          'auth_token': nextToken,
          if (expiredAt != null) 'expired_at': expiredAt,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.startsWith('/api/v2/payment_intents')) {
      final status = intentStatuses.isEmpty ? 200 : intentStatuses.removeAt(0);
      if (status == 401) {
        return http.Response(
          jsonEncode({
            'code': 'unauthorized',
            'type': 'unauthorized_error',
            'message': 'token expired',
          }),
          401,
          headers: intentHeaders,
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'pi_test_0001',
          'status': 'REQUIRES_PAYMENT_METHOD',
          'echo_body': request.body,
        }),
        status,
        headers: intentHeaders,
      );
    }
    return http.Response('not found', 404);
  }

  List<http.Request> get tokenRequests =>
      requests.where((r) => r.url.path == '/api/v1/connect/token').toList();

  List<http.Request> get intentRequests => requests
      .where((r) => r.url.path.startsWith('/api/v2/payment_intents'))
      .toList();
}

class Harness {
  Harness({Map<String, String> extraEnv = const {}, DateTime? start})
    : config = BackendConfig.fromEnvironment(baseEnv(extra: extraEnv)) {
    now = start ?? DateTime.utc(2026, 8, 18, 12);
    tokens = TokenManager(
      config: config,
      client: upstream.client,
      clock: () => now,
      log: logLines.add,
    );
    uqpay = UqpayClient(
      config: config,
      tokens: tokens,
      client: upstream.client,
    );
    app = BackendApp(
      config: config,
      tokens: tokens,
      uqpay: uqpay,
      clock: () => now,
      log: logLines.add,
    );
  }

  final BackendConfig config;
  final FakeUpstream upstream = FakeUpstream();
  final List<String> logLines = [];
  late DateTime now;
  late final TokenManager tokens;
  late final UqpayClient uqpay;
  late final BackendApp app;

  void advance(Duration d) => now = now.add(d);
}
