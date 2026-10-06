import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:flutter_test/flutter_test.dart';

/// The public surface is exactly what the two entry
/// libraries export, recorded in `test/goldens/public_api.txt` down to the
/// member SIGNATURES:
///
/// * every exported type's header — `sealed` / `final` / `abstract` /
///   `base` / `interface` modifiers, type parameters, `extends` / `with` /
///   `implements`;
/// * every public constructor, method, getter, setter, operator and field —
///   `static`, `const`, `final`, `factory`, return and parameter types,
///   positional vs optional vs named, `required`, and default values;
/// * enum values in declaration order (their index is observable), with their
///   constructor arguments (the wire values);
/// * the value of every `const` / `static` field (open value types such as
///   `UqpayErrorCode` carry their wire strings there).
///
/// So adding a required parameter, changing a type, dropping `const`, or
/// unsealing a class all fail this test — each of those is breaking in Dart.
/// Bodies, initializer lists and doc comments are deliberately not recorded:
/// they are not API.
///
/// Regenerating the golden is an explicit, reviewed act:
///
/// ```sh
/// flutter test test/public_api_snapshot_test.dart --update-goldens
/// ```
///
/// then review the diff of `test/goldens/public_api.txt` and note the change
/// in CHANGELOG.md.
///
/// Rules enforced on the entry files themselves:
/// * every `export` carries a `show` list — no wholesale re-export of a
///   `src/` file can leak an internal symbol;
/// * every shown symbol is actually declared in the file it is exported
///   from (catches typos and stale entries);
/// * `uqpay_sdk_flutter.dart` re-exports `headless.dart`, so the sheet
///   surface is a strict superset of the headless one.
void main() {
  const entryFiles = <String>[
    'lib/headless.dart',
    'lib/uqpay_sdk_flutter.dart',
  ];
  const goldenPath = 'test/goldens/public_api.txt';

  final exportPattern = RegExp(
    r"export\s+'([^']+)'(?:\s+show\s+([^;]+))?\s*;",
    multiLine: true,
  );

  /// Every exported symbol, mapped to the `lib/src` file declaring it.
  /// Re-exports of sibling entry libraries are followed.
  Map<String, String> exportedSymbols(String libraryPath) {
    final source = _stripComments(File(libraryPath).readAsStringSync());
    final symbols = <String, String>{};
    for (final match in exportPattern.allMatches(source)) {
      final target = match.group(1)!;
      final show = match.group(2);
      final targetPath = '${File(libraryPath).parent.path}/$target';
      if (target.startsWith('src/')) {
        expect(
          show,
          isNotNull,
          reason: '$libraryPath exports $target without a `show` list',
        );
        final names = show!
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        final targetSource = File(targetPath).readAsStringSync();
        for (final name in names) {
          expect(
            RegExp(
              r'^(?:abstract\s+|final\s+|sealed\s+|base\s+|interface\s+)*'
              r'(?:class|mixin|enum|typedef|extension type)\s+'
              '${RegExp.escape(name)}'
              r'\b',
              multiLine: true,
            ).hasMatch(targetSource),
            isTrue,
            reason: '$name is shown from $target but not declared there',
          );
          symbols[name] = targetPath;
        }
      } else {
        // A sibling entry library: include everything it exports.
        expect(
          show,
          isNull,
          reason: 'entry-library re-exports must be unfiltered ($libraryPath)',
        );
        symbols.addAll(exportedSymbols(targetPath));
      }
    }
    return symbols;
  }

  /// The full snapshot text: the symbol list per entry library (what a
  /// merchant can name), then one signature block per exported symbol (what
  /// they can call).
  String snapshot() {
    final out = StringBuffer();
    final all = <String, String>{};
    for (final entry in entryFiles) {
      final symbols = exportedSymbols(entry);
      all.addAll(symbols);
      out.writeln('# ${entry.substring('lib/'.length)}');
      (symbols.keys.toList()..sort()).forEach(out.writeln);
      out.writeln();
    }

    out
      ..writeln('# signatures')
      ..writeln();
    final units = <String, CompilationUnit>{};
    for (final name in all.keys.toList()..sort()) {
      final path = all[name]!;
      final unit = units.putIfAbsent(path, () => _parse(path));
      final declaration = unit.declarations.firstWhere(
        (d) => _declaredName(d) == name,
        orElse: () => fail('$name not found in $path by the parser'),
      );
      out.writeln(_signatureBlock(declaration));
    }
    return out.toString();
  }

  test(
    'the public API (names and signatures) matches the committed golden',
    () {
      final actual = snapshot();
      final golden = File(goldenPath);

      // `flutter test --update-goldens` is the one explicit way to accept an
      // API change (the pixel goldens follow the same rule).
      if (autoUpdateGoldenFiles) {
        golden.writeAsStringSync(actual);
        return;
      }

      expect(
        golden.existsSync(),
        isTrue,
        reason:
            'missing $goldenPath — create it with '
            '`flutter test $_selfPath --update-goldens`',
      );
      final expected = golden.readAsStringSync();
      expect(
        actual,
        expected,
        reason:
            'The public API changed:\n${_lineDiff(expected, actual)}\n'
            'If intentional (and semver-compatible), run '
            '`flutter test $_selfPath --update-goldens`, review the diff of '
            '$goldenPath, and note the change in CHANGELOG.md.',
      );
    },
  );

  test('no exported type inherits from a private type', () {
    // Members inherited from a private supertype would be public API that
    // the snapshot above cannot see.
    final all = <String, String>{};
    for (final entry in entryFiles) {
      all.addAll(exportedSymbols(entry));
    }
    for (final MapEntry(key: name, value: path) in all.entries) {
      final declaration = _parse(
        path,
      ).declarations.firstWhere((d) => _declaredName(d) == name);
      final header = _header(declaration);
      expect(
        RegExp(r'\b(extends|with|implements|on)\b.*\b_[A-Za-z]').hasMatch(
          header,
        ),
        isFalse,
        reason: '$name has a private supertype: $header',
      );
    }
  });

  test('the sheet library is a strict superset of the headless one', () {
    final headless = exportedSymbols('lib/headless.dart').keys.toSet();
    final full = exportedSymbols('lib/uqpay_sdk_flutter.dart').keys.toSet();
    expect(full.containsAll(headless), isTrue);
  });

  test(
    'no api-key parameter exists anywhere in the public surface',
    () {
      for (final entry in entryFiles) {
        final source = File(entry).readAsStringSync();
        expect(source.toLowerCase(), isNot(contains('apikey')));
        expect(source.toLowerCase(), isNot(contains('api_key')));
      }
      final srcFiles = Directory('lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final file in srcFiles) {
        final code = _stripComments(file.readAsStringSync()).toLowerCase();
        expect(
          code,
          isNot(contains('apikey')),
          reason: '${file.path} mentions an API key',
        );
        expect(code, isNot(contains('x-api-key')));
      }
    },
  );

  test('nothing under lib/ except the two entry files is a library entry', () {
    final topLevel = Directory(
      'lib',
    ).listSync().whereType<File>().map((f) => f.path).toSet();
    expect(topLevel, entryFiles.toSet());
  });
}

const _selfPath = 'test/public_api_snapshot_test.dart';

String _stripComments(String source) => source
    .replaceAll(RegExp(r'^\s*///?.*$', multiLine: true), '')
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');

CompilationUnit _parse(String path) {
  final result = parseString(
    content: File(path).readAsStringSync(),
    path: File(path).absolute.path,
  );
  return result.unit;
}

// ---------------------------------------------------------------------------
// Signature rendering. Purely syntactic (no element model): it reads the
// token stream between a declaration's first token and its body, so only
// a handful of long-stable AST getters are used.
// ---------------------------------------------------------------------------

const _headerModifiers = <String>{
  'abstract',
  'base',
  'class',
  'const',
  'enum',
  'extension',
  'final',
  'interface',
  'mixin',
  'sealed',
  'type',
  'typedef',
};

/// The name a top-level declaration introduces: the first token after its
/// modifiers and keywords.
String? _declaredName(CompilationUnitMember declaration) {
  Token? t = declaration.firstTokenAfterCommentAndMetadata;
  while (t != null && _headerModifiers.contains(t.lexeme)) {
    t = t.next;
  }
  return t?.lexeme;
}

/// A type's header: everything up to (not including) its body's `{`, or the
/// whole declaration for a typedef / class alias / top-level function.
String _header(CompilationUnitMember declaration) {
  final begin = declaration.firstTokenAfterCommentAndMetadata;
  if (declaration is FunctionDeclaration) {
    return _join(
      begin,
      declaration.functionExpression.body.beginToken.previous!,
    );
  }
  Token? t = begin;
  while (t != null && t != declaration.endToken) {
    if (t.type == TokenType.OPEN_CURLY_BRACKET) {
      return _join(begin, t.previous!);
    }
    t = t.next;
  }
  // No body: typedef, `class A = B with C;`, top-level variable.
  final end = declaration.endToken;
  return _join(begin, end.lexeme == ';' ? end.previous! : end);
}

String _signatureBlock(CompilationUnitMember declaration) {
  final out = StringBuffer()
    ..writeln('${_deprecation(declaration)}${_header(declaration)}');

  final enumValues = <String>[];
  final members = <String>[];
  void collect(SyntacticEntity entity) {
    if (entity is EnumConstantDeclaration) {
      enumValues.add(
        '${_deprecation(entity)}'
        '${_join(entity.firstTokenAfterCommentAndMetadata, entity.endToken)}',
      );
    } else if (entity is ClassMember) {
      members.addAll(_memberSignatures(entity));
    } else if (entity is AstNode) {
      entity.childEntities.forEach(collect);
    }
  }

  if (declaration is! FunctionDeclaration &&
      declaration is! TypeAlias &&
      declaration is! TopLevelVariableDeclaration) {
    declaration.childEntities.forEach(collect);
  }

  // Enum values stay in declaration order (`index` and `values` expose it);
  // other members are sorted so moving code around is not an API change.
  for (final value in enumValues) {
    out.writeln('  value $value');
  }
  for (final member in members..sort()) {
    out.writeln('  $member');
  }
  return out.toString();
}

Iterable<String> _memberSignatures(ClassMember member) sync* {
  final begin = member.firstTokenAfterCommentAndMetadata;
  final deprecated = _deprecation(member);
  switch (member) {
    case MethodDeclaration():
      if (member.name.lexeme.startsWith('_')) return;
      yield '$deprecated${_join(begin, member.body.beginToken.previous!)}';
    case ConstructorDeclaration():
      final name = member.name?.lexeme;
      if (name != null && name.startsWith('_')) return;
      // Cut before an initializer list (`: _x = x`) — implementation, not
      // API. A redirecting factory's `= Target` is kept.
      final separator = member.separator;
      final end = separator != null && separator.lexeme == ':'
          ? separator.previous!
          : member.body.beginToken.previous!;
      yield '$deprecated${_join(begin, end)}';
    case FieldDeclaration():
      final variables = member.fields.variables;
      final prefix = variables.first.beginToken == begin
          ? ''
          : '${_join(begin, variables.first.beginToken.previous!)} ';
      final recordValue = member.fields.isConst || member.isStatic;
      for (final variable in variables) {
        final name = variable.name.lexeme;
        if (name.startsWith('_')) continue;
        final initializer = variable.initializer;
        final value = recordValue && initializer != null
            ? ' = ${_join(initializer.beginToken, initializer.endToken)}'
            : '';
        yield '$deprecated$prefix$name$value';
      }
    default:
      yield '$deprecated${_join(begin, member.endToken)}';
  }
}

/// Annotations that change what a member's API status is (deprecated, not
/// for merchants, or constrained for subclasses). `@override` and friends
/// are noise and left out.
const _apiAnnotations = <String>{
  'Deprecated',
  'deprecated',
  'internal',
  'immutable',
  'mustCallSuper',
  'nonVirtual',
  'protected',
  'visibleForOverriding',
  'visibleForTesting',
};

String _deprecation(AnnotatedNode node) {
  final out = StringBuffer();
  for (final annotation in node.metadata) {
    if (_apiAnnotations.contains(annotation.name.name)) {
      out.write('${_join(annotation.beginToken, annotation.endToken)} ');
    }
  }
  return out.toString();
}

const _noSpaceBefore = <String>{
  ',',
  ':',
  ';',
  ')',
  ']',
  '>',
  '>>',
  '>>>',
  '?',
  '.',
  '?.',
  '!',
};
const _noSpaceAfter = <String>{'(', '[', '<', '.', '?.', '@'};
const _closers = <String?>{')', ']', '}', '>', '>>', '>>>'};

/// Joins the tokens [begin]..[end] (inclusive) with canonical spacing, so the
/// snapshot is independent of formatting and comments.
String _join(Token begin, Token end) {
  final out = StringBuffer();
  Token? previous;
  for (Token? t = begin; t != null; t = t.next) {
    final lexeme = t.lexeme;
    // A trailing comma is formatter style (and the formatter's choice
    // differs between Dart versions), never API.
    if (lexeme == ',' && t != end && _closers.contains(t.next?.lexeme)) {
      continue;
    }
    if (previous != null) {
      final glue =
          _noSpaceBefore.contains(lexeme) ||
          _noSpaceAfter.contains(previous.lexeme) ||
          // Type arguments and calls: `List<int>`, `Foo(`, `Function(`.
          ((lexeme == '<' || lexeme == '(' || lexeme == '[') &&
              (previous.isIdentifier ||
                  previous.lexeme == '>' ||
                  previous.lexeme == 'Function'));
      if (!glue) out.write(' ');
    }
    out.write(lexeme);
    previous = t;
    if (t == end || t.type == TokenType.EOF) break;
  }
  return out.toString();
}

/// A minimal line diff (removed `-` / added `+`) so a failure names the
/// changed signatures instead of dumping the whole file.
String _lineDiff(String expected, String actual) {
  final before = expected.split('\n');
  final after = actual.split('\n');
  final removed = before.where((l) => !after.contains(l)).map((l) => '- $l');
  final added = after.where((l) => !before.contains(l)).map((l) => '+ $l');
  return [...removed, ...added].join('\n');
}
