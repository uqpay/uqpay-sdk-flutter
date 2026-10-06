import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uqpay_sdk_flutter_example/src/backend/merchant_backend.dart';

const String _backendUrl = 'http://localhost:8787';

void main() {
  group('MerchantBackend.authToken', () {
    late List<http.Request> requests;
    late List<String> tokens;
    late MerchantBackend backend;

    setUp(() {
      requests = <http.Request>[];
      tokens = <String>['tok_first_aaaa1111', 'tok_second_bbbb2222'];
      backend = MerchantBackend(
        baseUrl: _backendUrl,
        httpClient: MockClient((request) async {
          requests.add(request);
          final token = tokens.isEmpty ? 'tok_more' : tokens.removeAt(0);
          return http.Response(
            jsonEncode(<String, Object?>{
              'auth_token': token,
              'expired_at':
                  DateTime.now()
                      .add(const Duration(minutes: 30))
                      .millisecondsSinceEpoch ~/
                  1000,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }),
      );
    });

    tearDown(() => backend.close());

    test('first call sends no body', () async {
      final token = await backend.authToken();
      expect(token.value, 'tok_first_aaaa1111');
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/client-token');
      expect(requests.single.body, isEmpty);
    });

    test(
      'later calls name the previous token by its last four characters only',
      () async {
        await backend.authToken();
        final second = await backend.authToken();
        expect(second.value, 'tok_second_bbbb2222');

        final body = jsonDecode(requests[1].body) as Map<String, Object?>;
        expect(body, <String, Object?>{'rejected_token_suffix': '1111'});
        expect(requests[1].body, isNot(contains('tok_first')));

        // The third call names the second token, not the first.
        await backend.authToken();
        expect(
          jsonDecode(requests[2].body),
          <String, Object?>{'rejected_token_suffix': '2222'},
        );
      },
    );
  });
}
