import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source tripwires specific to the 3DS layer:
/// `dart:html` must never appear, and `webview_flutter` must be reachable
/// only through the `dart.library.io` branch of the conditional import so
/// web (JS **and** wasm) builds never compile it.
void main() {
  final libFiles =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  List<String> hits(RegExp pattern, {List<String> allowFiles = const []}) {
    final found = <String>[];
    for (final file in libFiles) {
      if (allowFiles.any(file.path.contains)) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) {
          continue;
        }
        if (pattern.hasMatch(lines[i])) {
          found.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    return found;
  }

  test('no dart:html anywhere in lib/ (wasm-safe)', () {
    expect(hits(RegExp(r'''import\s+["']dart:html''')), isEmpty);
  });

  test('webview_flutter is imported only by the _io conditional branch', () {
    expect(
      hits(
        RegExp(r'''import\s+["']package:webview_flutter'''),
        allowFiles: ['webview_challenge_presenter_io.dart'],
      ),
      isEmpty,
    );
    expect(
      File(
        'lib/src/three_ds/webview_challenge_presenter_io.dart',
      ).readAsStringSync(),
      contains("import 'package:webview_flutter/webview_flutter.dart'"),
    );
  });

  test('the page selects the webview via a conditional import with an '
      'explicit js_interop branch', () {
    final page = File(
      'lib/src/three_ds/uqpay_challenge_page.dart',
    ).readAsStringSync();
    expect(page, contains('if (dart.library.js_interop)'));
    expect(page, contains('if (dart.library.io)'));
    expect(
      page,
      contains('webview_challenge_presenter_stub.dart'),
      reason: 'web/wasm builds get the stub, never webview_flutter',
    );
  });

  test('url_launcher is imported only by the redirect presenter and the '
      'io webview (external links)', () {
    expect(
      hits(
        RegExp(r'''import\s+["']package:url_launcher'''),
        allowFiles: [
          'redirect_challenge_presenter.dart',
          'webview_challenge_presenter_io.dart',
        ],
      ),
      isEmpty,
    );
  });

  test('the SDK never touches the app-global webview cookie jar', () {
    // WebViewCookieManager().clearCookies() wipes every cookie of every
    // webview in the HOST app (logging the merchant's own webviews out).
    expect(hits(RegExp('WebViewCookieManager|clearCookies')), isEmpty);
  });

  test('the web redirect uses _self — a same-tab redirect, never a popup', () {
    final presenter = File(
      'lib/src/three_ds/redirect_challenge_presenter.dart',
    ).readAsStringSync();
    expect(presenter, contains("webOnlyWindowName: '_self'"));
  });
}
