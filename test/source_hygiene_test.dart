import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Source-level tripwires for the SDK's coding rules. Each one greps
/// `lib/src` and fails the build on a forbidden pattern.
void main() {
  final libSrc = Directory('lib/src');
  final dartFiles =
      libSrc
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('lib/src exists and has sources', () {
    expect(dartFiles, isNotEmpty);
  });

  /// Returns `file:line: source` for every line of every file matching
  /// [pattern], excluding files whose path contains any of [allowFiles] and
  /// excluding comment lines.
  List<String> hits(RegExp pattern, {List<String> allowFiles = const []}) {
    final found = <String>[];
    for (final file in dartFiles) {
      if (allowFiles.any(file.path.contains)) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.trimLeft();
        if (code.startsWith('//')) {
          continue;
        }
        if (pattern.hasMatch(line)) {
          found.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    return found;
  }

  group('clock seam', () {
    const clockFile = 'lib/src/core/uqpay_clock.dart';

    test('no DateTime.now() outside the clock seam', () {
      expect(
        hits(RegExp(r'DateTime\.now\('), allowFiles: [clockFile]),
        isEmpty,
      );
    });

    test('no Future.delayed outside the clock seam', () {
      expect(
        hits(RegExp(r'Future(<[^>]*>)?\.delayed\('), allowFiles: [clockFile]),
        isEmpty,
      );
    });

    test('no Timer construction outside the clock seam', () {
      expect(
        hits(RegExp(r'\bTimer(\.periodic)?\('), allowFiles: [clockFile]),
        isEmpty,
      );
    });

    test('the clock seam itself is the only wall-clock user', () {
      final clock = File(clockFile).readAsStringSync();
      expect(clock, contains('DateTime.now()'));
      expect(clock, contains('Future<void>.delayed('));
    });
  });

  group('no amount scaling anywhere', () {
    test('no `* 100`, `/ 100`, `*100`, `/100` in lib/src', () {
      expect(hits(RegExp(r'[*/]\s*100\b')), isEmpty);
    });

    test('no `pow(` or `math.pow` in lib/src', () {
      expect(hits(RegExp(r'\bpow\(')), isEmpty);
    });

    test('no double conversion of amounts in lib/src', () {
      // `toDouble()` / `double.parse` on money is the classic mis-scaling
      // vector; the SDK has no legitimate use for either.
      expect(hits(RegExp(r'\.toDouble\(\)|double\.(try)?[pP]arse\(')), isEmpty);
    });
  });

  group('logging and platform hygiene', () {
    test('no print / debugPrint / log() in lib/src outside the one opt-in '
        'logger sink', () {
      // `uqpay_logger.dart` is the single sanctioned sink: it is off by
      // default, receives only identifiers and status words (never a body,
      // PAN, CVC or token — see redaction_test.dart) and is the only file
      // allowed to call `developer.log`.
      expect(
        hits(
          // `_logger.log(` is the sink's own API; anything else named log(
          // is a stray diagnostic.
          RegExp(r'(?<!_logger\.)\b(print|debugPrint|log|developer\.log)\('),
          allowFiles: ['uqpay_logger.dart'],
        ),
        isEmpty,
      );
    });

    test('dart:io is imported only by *_io.dart files', () {
      expect(
        hits(RegExp("import 'dart:io'"), allowFiles: ['_io.dart']),
        isEmpty,
      );
    });

    test('dart:html and dart:mirrors are never imported', () {
      expect(hits(RegExp("import 'dart:(html|mirrors)'")), isEmpty);
    });

    test('UqpayErrorCode values are minted only by the error mapper '
        '(no second error mapper)', () {
      // Server strings become error codes in exactly one place. Anything
      // else that needs a code refers to a named constant.
      expect(
        hits(
          RegExp(r'UqpayErrorCode\.fromRaw\('),
          allowFiles: ['lib/src/errors/'],
        ),
        isEmpty,
      );
      expect(
        hits(
          RegExp(r'UqpayErrorCode\._\('),
          allowFiles: ['lib/src/errors/uqpay_error_code.dart'],
        ),
        isEmpty,
      );
    });

    test('no wire value derived from runtimeType', () {
      // `runtimeType` is permitted only in equality/toString on the model
      // base class: under `--obfuscate` it is a minified name.
      final runtimeTypeHits = hits(
        RegExp('runtimeType'),
        allowFiles: ['uqpay_json_model.dart'],
      );
      expect(runtimeTypeHits, isEmpty);
    });

    test('no wire value derived from Type.toString()', () {
      expect(
        hits(
          RegExp(
            // `Foo.toString()`, `(Foo).toString()`, `'${Foo}'` on a type
            // literal (UpperCamelCase; Dart constants are lowerCamelCase).
            r'(\b[A-Z]\w*|\(\s*[A-Z]\w*\s*\))\.toString\(\)'
            r'|\$\{\s*[A-Z]\w*\s*\}',
          ),
        ),
        isEmpty,
        reason:
            'a type literal stringified is an obfuscated identifier in a '
            'release build',
      );
    });

    // Every `<receiver>.name` property read in lib/src. `Enum.name` is a
    // Dart identifier, not a wire value: obfuscation can rename it and a
    // rename refactor silently changes the wire. Wire values come from
    // `.raw` (the SDK's open value types) or an explicit field such as
    // `UqpayCardBrand.wireName`.
    //
    // Two checks, both purely syntactic (no type resolution needed):
    //  1. Every `.name` read must be on the reviewed allow-list below
    //     (file -> receiver expressions). A new one fails until a reviewer
    //     confirms it is not an enum reaching the wire, and adds it.
    //  2. Even an allow-listed `.name` must not appear inside a JSON / header
    //     / body / query construct: a map or set literal, a `headers:` /
    //     `body:` / `queryParameters:` argument, an `x[...] = ` assignment,
    //     a `jsonEncode(...)` call, or a method whose name says it builds
    //     the wire (`toJson`, `toWire...`, `...Headers`, `...Body`, ...).
    const nameReadAllowList = <String, Set<String>>{
      // Enum.name — diagnostics only (error messages / toString / logger).
      'lib/src/uqpay_sdk.dart': {'environment'},
      'lib/src/transport/transport_failure.dart': {'kind'},
      'lib/src/transport/uqpay_api_client.dart': {'e.kind'},
      'lib/src/transport/http_package_client.dart': {'kind'},
      'lib/src/sheet/qr/qr_matrix.dart': {'errorCorrection'},
      'lib/src/sheet/qr/qr_encoder.dart': {'level'},
      // Not enums: a `String name` field and Flutter's `TextInputType.name`
      // constant.
      'lib/src/sheet/card/billing_countries.dart': {'other', 'a', 'b'},
      'lib/src/sheet/widgets/card_form_view.dart': {
        'TextInputType',
        'country',
      },
    };

    test('Enum.name never reaches a header, body or JSON', () {
      final unlisted = <String>[];
      final onWire = <String>[];
      for (final file in dartFiles) {
        final path = file.path.replaceAll(r'\', '/');
        final source = file.readAsStringSync();
        final unit = parseString(
          content: source,
          path: file.absolute.path,
          throwIfDiagnostics: false,
        ).unit;
        final visitor = _NameReadVisitor();
        unit.accept(visitor);
        for (final read in visitor.reads) {
          final line = unit.lineInfo.getLocation(read.node.offset).lineNumber;
          final where = '$path:$line: ${read.node.toSource()}';
          if (!(nameReadAllowList[path]?.contains(read.receiver) ?? false)) {
            unlisted.add(where);
          }
          final context = _wireContext(read.node);
          if (context != null) {
            onWire.add('$where (inside $context)');
          }
        }
      }
      expect(
        unlisted,
        isEmpty,
        reason:
            'new `.name` reads in lib/src. If the receiver is an enum and '
            'the value can reach the wire, use an explicit wire field '
            'instead; otherwise add it to nameReadAllowList.',
      );
      expect(onWire, isEmpty, reason: '`.name` used to build a wire value');
    });

    test('the Enum.name check sees the reads it allow-lists', () {
      // Guards the check itself: if the visitor stopped matching, the test
      // above would pass vacuously.
      final seen = <String, Set<String>>{};
      for (final path in nameReadAllowList.keys) {
        final unit = parseString(
          content: File(path).readAsStringSync(),
          path: File(path).absolute.path,
          throwIfDiagnostics: false,
        ).unit;
        final visitor = _NameReadVisitor();
        unit.accept(visitor);
        seen[path] = visitor.reads.map((r) => r.receiver).toSet();
      }
      for (final MapEntry(key: path, value: receivers)
          in nameReadAllowList.entries) {
        expect(
          seen[path],
          containsAll(receivers),
          reason: 'stale allow-list entry for $path — remove it',
        );
      }

      // And it flags a wire use.
      final probe = parseString(
        content: '''
enum E { a }
Map<String, Object?> toJson(E e) => {'kind': e.name};
void send(E e, Map<String, String> headers) { headers['x-kind'] = e.name; }
''',
        throwIfDiagnostics: false,
      ).unit;
      final visitor = _NameReadVisitor();
      probe.accept(visitor);
      expect(
        visitor.reads.map((r) => _wireContext(r.node)),
        everyElement(isNotNull),
      );
      expect(visitor.reads, hasLength(2));
    });
  });
}

/// A `<receiver>.name` property read.
typedef _NameRead = ({AstNode node, String receiver});

class _NameReadVisitor extends RecursiveAstVisitor<void> {
  final reads = <_NameRead>[];

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'name') {
      reads.add((node: node, receiver: node.prefix.name));
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.target;
    if (node.propertyName.name == 'name' && target != null) {
      reads.add((node: node, receiver: target.toSource()));
    }
    super.visitPropertyAccess(node);
  }
}

const _wireArgumentNames = <String>{
  'body',
  'headers',
  'query',
  'queryParameters',
};
final _wireMethodName = RegExp(
  'json|wire|header|body|query|payload|canonical',
  caseSensitive: false,
);

/// Describes the wire-building construct enclosing [node], or null.
String? _wireContext(AstNode node) {
  AstNode? child = node;
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    switch (parent) {
      case SetOrMapLiteral():
        return 'a map/set literal';
      case NamedExpression(:final name)
          when _wireArgumentNames.contains(name.label.name):
        return 'a `${name.label.name}:` argument';
      case AssignmentExpression(:final leftHandSide)
          when leftHandSide is IndexExpression && child != leftHandSide:
        return 'an index assignment';
      case MethodInvocation(:final methodName)
          when methodName.name == 'jsonEncode' || methodName.name == 'encode':
        return '`${methodName.name}(...)`';
      case MethodDeclaration(:final name)
          when _wireMethodName.hasMatch(name.lexeme):
        return 'method `${name.lexeme}`';
      case FunctionDeclaration(:final name)
          when _wireMethodName.hasMatch(name.lexeme):
        return 'function `${name.lexeme}`';
    }
    child = parent;
  }
  return null;
}
