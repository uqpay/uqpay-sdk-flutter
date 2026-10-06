import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uqpay_sdk_flutter/src/three_ds/webview_challenge_presenter_io.dart';

/// The `redirect_iframe` fallback submit must live inside the fragment's own
/// document. Injected from the webview's page-finished callback it ran on
/// the ACS integrator page instead, posted that page's form before the 3DS
/// method finished, and failed every authentication.
void main() {
  const fragment =
      '<iframe style="display:none"></iframe> '
      '<form method="POST" target="_top" action="https://acs.example/auth"> '
      '<input type="hidden" name="k" value="v"></form>';

  test('the fragment is embedded verbatim in a full document', () {
    final html = wrapIframeFragment(fragment);
    expect(html, startsWith('<!doctype html>'));
    expect(html, contains(fragment));
    expect(html, contains('name="viewport"'));
  });

  test('the fallback submit runs on the wrapper document load, after the '
      'fragment', () {
    final html = wrapIframeFragment(fragment);
    final script = html.indexOf('<script>');
    expect(script, greaterThan(html.indexOf(fragment)));
    expect(html, contains("window.addEventListener('load', submit)"));
    expect(html, contains("document.readyState === 'complete'"));
  });

  test('no form submit is injected into whatever page is current', () {
    final source = File(
      'lib/src/three_ds/webview_challenge_presenter_io.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('runJavaScript')));
  });
}
