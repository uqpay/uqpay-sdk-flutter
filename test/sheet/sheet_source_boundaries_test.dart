import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guarantees about the drop-in sheet.
///
/// * **Import boundary** — the sheet is a *consumer* of the public headless
///   API, not a privileged insider: nothing under `lib/src/sheet` (or
///   `lib/src/l10n`) may import an SDK internal such as `src/transport`, `src/idempotency`,
///   `src/three_ds`, `src/flow` or `src/models`. Whatever the sheet does, a
///   merchant can do with the same public symbols.
/// * **No hardcoded strings** — no user-facing string literal lives in
///   widget code: every one comes from `UqpayLocalizations`, so a merchant
///   can override it.
void main() {
  final sheetFiles =
      <File>[
          ...Directory(
            'lib/src/sheet',
          ).listSync(recursive: true).whereType<File>(),
          ...Directory(
            'lib/src/l10n',
          ).listSync(recursive: true).whereType<File>(),
        ].where((f) => f.path.endsWith('.dart')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('the sheet has sources to check', () {
    expect(sheetFiles, isNotEmpty);
  });

  group('import boundary', () {
    final importPattern = RegExp(r"^import\s+'([^']+)'", multiLine: true);

    /// The only package imports the sheet may make.
    bool isAllowed(String uri) {
      if (uri.startsWith('dart:')) {
        return true;
      }
      if (uri.startsWith('package:flutter/') ||
          uri.startsWith('package:intl/')) {
        return true;
      }
      if (uri == 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart' ||
          uri == 'package:uqpay_sdk_flutter/headless.dart') {
        // The public barrels: the same API a merchant imports.
        return true;
      }
      if (uri.startsWith('package:uqpay_sdk_flutter/src/sheet/') ||
          uri.startsWith('package:uqpay_sdk_flutter/src/l10n/')) {
        // Its own siblings.
        return true;
      }
      // A relative import inside the sheet's own directories is a sibling
      // too; anything else reaches outside.
      return !uri.startsWith('package:') && !uri.contains('..');
    }

    test('no file under lib/src/sheet or lib/src/l10n imports an SDK '
        'internal', () {
      final violations = <String>[];
      for (final file in sheetFiles) {
        final source = file.readAsStringSync();
        for (final match in importPattern.allMatches(source)) {
          final uri = match.group(1)!;
          if (!isAllowed(uri)) {
            violations.add('${file.path}: $uri');
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason:
            'the sheet must reach the SDK only through its public API '
            '— offending imports:\n${violations.join('\n')}',
      );
    });

    test('the forbidden internals are named explicitly, so the rule cannot '
        'rot silently', () {
      const forbidden = <String>[
        'src/transport/',
        'src/idempotency/',
        'src/three_ds/',
        'src/flow/',
        'src/models/',
        'src/errors/',
        'src/money/',
      ];
      for (final file in sheetFiles) {
        final source = file.readAsStringSync();
        for (final internal in forbidden) {
          expect(
            source.contains("import 'package:uqpay_sdk_flutter/$internal"),
            isFalse,
            reason: '${file.path} imports $internal directly',
          );
        }
      }
    });
  });

  group('no hardcoded user-facing strings', () {
    /// `Text('…')` — a string the merchant could never translate.
    final textLiteral = RegExp(r'''\bText\(\s*['"]''');

    /// A user-facing label/hint/tooltip given as a literal.
    final labelLiteral = RegExp(
      r'''\b(label|tooltip|labelText|hintText|helperText|errorText|'''
      r'''semanticLabel|semanticsLabel)\s*:\s*['"]''',
    );

    test('widget code never builds a Text from a literal', () {
      final violations = <String>[];
      for (final file in sheetFiles) {
        if (file.path.contains('uqpay_localizations.dart')) {
          continue; // The catalogue *is* the strings.
        }
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) {
            continue;
          }
          if (textLiteral.hasMatch(line) || labelLiteral.hasMatch(line)) {
            violations.add('${file.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason:
            'every user-facing string must come from UqpayLocalizations:\n'
            '${violations.join('\n')}',
      );
    });
  });
}
