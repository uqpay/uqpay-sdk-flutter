// The README quickstart is copy-pasteable and compiles verbatim.
//
// `readme_quickstart.dart` holds the snippet as REAL code between two
// markers; importing it here forces the compiler and the analyzer over it on
// every CI run. This test then asserts the README's ```dart block under
// "## Quickstart" is byte-identical to that region — so the published
// instructions cannot drift from an API that still compiles.
//
// To sync after an intentional edit to the snippet:
//   UPDATE_README_QUICKSTART=1 flutter test test/docs/readme_quickstart_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Imported purely so CI compiles and analyses the snippet; nothing here calls
// it. That compilation IS the guarantee.
// ignore: unused_import
import 'readme_quickstart.dart';

const String _begin = '// --8<-- README QUICKSTART BEGIN';
const String _end = '// --8<-- README QUICKSTART END';

String _snippetFromSource() {
  final source = File('test/docs/readme_quickstart.dart').readAsStringSync();
  final start = source.indexOf(_begin);
  final finish = source.indexOf(_end);
  expect(start, isNonNegative, reason: 'BEGIN marker missing');
  expect(finish, greaterThan(start), reason: 'END marker missing');
  final body = source.substring(start + _begin.length, finish).trim();
  return "import 'package:uqpay_sdk_flutter/uqpay_sdk_flutter.dart';\n\n$body";
}

({int start, int end, String code}) _readmeQuickstart() {
  final readme = File('README.md').readAsStringSync();
  final heading = readme.indexOf('## Quickstart');
  expect(heading, isNonNegative, reason: 'README has no "## Quickstart"');
  final open = readme.indexOf('```dart', heading);
  expect(open, isNonNegative, reason: 'Quickstart has no ```dart block');
  final codeStart = readme.indexOf('\n', open) + 1;
  final close = readme.indexOf('```', codeStart);
  expect(close, isNonNegative, reason: 'unterminated ```dart block');
  return (
    start: codeStart,
    end: close,
    code: readme.substring(codeStart, close).trim(),
  );
}

void main() {
  test('the README quickstart matches the compiled snippet', () {
    final expected = _snippetFromSource();
    final readmeFile = File('README.md');
    final block = _readmeQuickstart();

    if (Platform.environment['UPDATE_README_QUICKSTART'] == '1') {
      final readme = readmeFile.readAsStringSync();
      readmeFile.writeAsStringSync(
        '${readme.substring(0, block.start)}$expected\n'
        '${readme.substring(block.end)}',
      );
      return;
    }

    expect(
      block.code,
      expected,
      reason:
          'README.md "## Quickstart" has drifted from '
          'test/docs/readme_quickstart.dart, which is real compiled code. '
          'Sync it with: UPDATE_README_QUICKSTART=1 flutter test '
          'test/docs/readme_quickstart_test.dart',
    );
  });
}
