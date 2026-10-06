import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/return_url_matcher.dart';

/// The pure return-URL recognition used by every presenter.
///
/// The webview's navigation policy — [challengeNavigationFor] — is tested
/// here as a pure function;
/// `test/regression/edge_3ds_webview_page_test.dart` drives the real page
/// through a fake webview platform.
void main() {
  final returnUrl = Uri.parse('https://shop.example/checkout/return');

  bool matches(String candidate) => UqpayReturnUrlMatcher.matches(
    candidate: Uri.parse(candidate),
    returnUrl: returnUrl,
  );

  group('UqpayReturnUrlMatcher.matches', () {
    test('exact match', () {
      expect(matches('https://shop.example/checkout/return'), isTrue);
    });

    test('extra query parameters are allowed and ignored', () {
      expect(
        matches(
          'https://shop.example/checkout/return'
          '?status=failed&uqpay_intent=pi_1',
        ),
        isTrue,
      );
    });

    test('fragments are allowed and ignored', () {
      expect(matches('https://shop.example/checkout/return#done'), isTrue);
    });

    test('deeper path at a segment boundary matches', () {
      expect(matches('https://shop.example/checkout/return/done'), isTrue);
    });

    test('a path that merely shares a prefix string does not match', () {
      expect(matches('https://shop.example/checkout/returnable'), isFalse);
    });

    test('a shorter path does not match', () {
      expect(matches('https://shop.example/checkout'), isFalse);
    });

    test('wrong host does not match', () {
      expect(matches('https://evil.example/checkout/return'), isFalse);
    });

    test('a host that suffixes the return host does not match', () {
      expect(matches('https://shop.example.evil.io/checkout/return'), isFalse);
    });

    test('wrong scheme does not match (https downgrade)', () {
      expect(matches('http://shop.example/checkout/return'), isFalse);
    });

    test('scheme and host compare case-insensitively', () {
      expect(matches('HTTPS://SHOP.Example/checkout/return'), isTrue);
    });

    test('the path compares case-sensitively', () {
      expect(matches('https://shop.example/Checkout/Return'), isFalse);
    });

    test('trailing slashes are equivalent', () {
      expect(matches('https://shop.example/checkout/return/'), isTrue);
      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('https://shop.example/checkout/return'),
          returnUrl: Uri.parse('https://shop.example/checkout/return/'),
        ),
        isTrue,
      );
    });

    test('an explicit non-default port must match', () {
      expect(matches('https://shop.example:8443/checkout/return'), isFalse);
      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('https://shop.example:8443/a'),
          returnUrl: Uri.parse('https://shop.example:8443/a'),
        ),
        isTrue,
      );
    });

    test('the default port and no port are equivalent', () {
      expect(matches('https://shop.example:443/checkout/return'), isTrue);
    });

    test('app-scheme return URL: host and scheme, empty path', () {
      final appReturn = Uri.parse('myapp://payment');
      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('myapp://payment?status=whatever'),
          returnUrl: appReturn,
        ),
        isTrue,
      );
      expect(
        UqpayReturnUrlMatcher.matches(
          candidate: Uri.parse('otherapp://payment'),
          returnUrl: appReturn,
        ),
        isFalse,
      );
    });
  });

  group('challengeNavigationFor (the webview navigation policy)', () {
    ChallengeNavigation decide(
      String url, {
      Uri? returnTo,
      bool mainFrame = true,
    }) => challengeNavigationFor(
      navigationUrl: url,
      returnUrl: returnTo ?? returnUrl,
      isMainFrame: mainFrame,
    );

    ChallengeNavigationKind kind(
      String url, {
      Uri? returnTo,
      bool mainFrame = true,
    }) => decide(url, returnTo: returnTo, mainFrame: mainFrame).kind;

    final appReturn = Uri.parse('myapp://payment');
    final sentinel = Uri(scheme: 'uqpay-return', host: 'none');

    test('the return URL completes with the observed URI', () {
      final d = decide('https://shop.example/checkout/return?ok=1');
      expect(d.kind, ChallengeNavigationKind.returned);
      expect(d.uri, Uri.parse('https://shop.example/checkout/return?ok=1'));
    });

    test('ordinary http(s) navigations keep loading', () {
      expect(
        kind('https://acs.bank.example/challenge/step2'),
        ChallengeNavigationKind.load,
      );
      expect(
        kind('http://acs.bank.example/challenge'),
        ChallengeNavigationKind.load,
      );
    });

    test('about:, data: and blob: keep loading (ACS interstitials)', () {
      expect(kind('about:blank'), ChallengeNavigationKind.load);
      expect(kind('data:text/html,<p>hi</p>'), ChallengeNavigationKind.load);
    });

    test("the return URL's own app scheme ends the browser step", () {
      final d = decide('myapp://payment?via=bank', returnTo: appReturn);
      expect(d.kind, ChallengeNavigationKind.returned);
      expect(d.uri!.scheme, 'myapp');
      // Any host/path under the app scheme, case-insensitively.
      expect(
        kind('MyApp://other/path', returnTo: appReturn),
        ChallengeNavigationKind.returned,
      );
    });

    test('a banking-app deep link is launched, never a return', () {
      for (final url in [
        'bankapp://authenticate?tx=1',
        'intent://approve#Intent;scheme=bank;package=com.bank;end',
        'itms-apps://apps.apple.com/app/id1',
        'market://details?id=com.bank',
      ]) {
        expect(
          kind(url, returnTo: appReturn),
          ChallengeNavigationKind.launchExternally,
          reason: url,
        );
        expect(
          kind(url),
          ChallengeNavigationKind.launchExternally,
          reason: '$url (https return URL)',
        );
      }
    });

    test('tel:, mailto: and sms: are launched and keep the challenge', () {
      for (final url in [
        'tel:+6500000000',
        'mailto:support@bank.example',
        'sms:+6500000000',
      ]) {
        expect(kind(url), ChallengeNavigationKind.launchExternally);
        expect(
          kind(url, returnTo: sentinel),
          ChallengeNavigationKind.launchExternally,
          reason: 'never a return, even under the sentinel',
        );
      }
    });

    test('file:, content: and javascript: are blocked, never launched', () {
      for (final url in [
        'file:///etc/hosts',
        'content://com.app.provider/x',
        'javascript:alert(1)',
        'chrome-error://chromewebdata/',
      ]) {
        expect(kind(url), ChallengeNavigationKind.block, reason: url);
        expect(
          kind(url, returnTo: sentinel),
          ChallengeNavigationKind.block,
          reason: '$url (sentinel)',
        );
      }
    });

    test('the sentinel keeps the old rule: other non-web schemes return', () {
      expect(
        kind('myapp://payment', returnTo: sentinel),
        ChallengeNavigationKind.returned,
      );
      expect(
        kind('bankapp://authenticate', returnTo: sentinel),
        ChallengeNavigationKind.returned,
      );
      expect(
        kind('https://shop.example/anything', returnTo: sentinel),
        ChallengeNavigationKind.load,
      );
    });

    test('sub-frame navigations never end the challenge', () {
      expect(
        kind('https://shop.example/checkout/return?x=1', mainFrame: false),
        ChallengeNavigationKind.load,
      );
      expect(
        kind('myapp://payment', returnTo: appReturn, mainFrame: false),
        ChallengeNavigationKind.block,
      );
      expect(
        kind('bankapp://probe', mainFrame: false),
        ChallengeNavigationKind.block,
      );
      expect(
        kind('bankapp://probe', returnTo: sentinel, mainFrame: false),
        ChallengeNavigationKind.block,
      );
    });

    test('a malformed URL keeps loading and never throws', () {
      expect(kind('::not a uri::%%'), ChallengeNavigationKind.load);
    });

    test('an empty URL keeps loading', () {
      expect(kind(''), ChallengeNavigationKind.load);
    });
  });
}
