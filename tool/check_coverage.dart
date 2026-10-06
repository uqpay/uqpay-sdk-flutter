// Enforces the SDK's coverage floors against `coverage/lcov.info`.
//
//   flutter test --coverage && dart run tool/check_coverage.dart
//
// Overall must be >= 85%. The files listed in `_mustBeTotal` must be 100%:
// each one is a place where a wrong answer means a wrong amount charged, a
// wrong error shown, or a double charge.
import 'dart:io';

const double _overallFloor = 85;

const List<String> _mustBeTotal = <String>[
  'lib/src/money/uqpay_amount.dart',
  'lib/src/errors/error_mapper.dart',
  'lib/src/errors/uqpay_error_code.dart',
  'lib/src/errors/uqpay_error.dart',
  'lib/src/idempotency/idempotency_store.dart',
  'lib/src/models/uqpay_intent_status.dart',
  'lib/src/models/uqpay_attempt_status.dart',
  'lib/src/flow/uqpay_payment_flow.dart',
  'lib/src/flow/intent_outcome.dart',
  'lib/src/flow/polling_policy.dart',
  'lib/src/idempotency/key_value_store.dart',
  'lib/src/sheet/card/card_validation.dart',
];

void main() {
  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln(
      'coverage/lcov.info not found — run `flutter test --coverage` first.',
    );
    exit(2);
  }

  final perFile = <String, ({int hit, int found})>{};
  String? current;
  var hit = 0;
  var found = 0;

  for (final line in lcov.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      current = line.substring(3).replaceFirst(RegExp('^.*?(?=lib/)'), '');
      hit = 0;
      found = 0;
    } else if (line.startsWith('DA:')) {
      final parts = line.substring(3).split(',');
      found++;
      if (parts.length > 1 && int.tryParse(parts[1]) != 0) {
        hit++;
      }
    } else if (line == 'end_of_record' && current != null) {
      perFile[current] = (hit: hit, found: found);
      current = null;
    }
  }

  final totalFound = perFile.values.fold<int>(0, (a, b) => a + b.found);
  final totalHit = perFile.values.fold<int>(0, (a, b) => a + b.hit);
  final overall = totalFound == 0 ? 0.0 : totalHit * 100 / totalFound;

  final failures = <String>[];

  if (overall < _overallFloor) {
    failures.add(
      'overall coverage ${overall.toStringAsFixed(1)}% is below the '
      '${_overallFloor.toStringAsFixed(0)}% floor',
    );
  }

  for (final path in _mustBeTotal) {
    final entry = perFile[path];
    if (entry == null) {
      failures.add('$path has no coverage record — was it renamed?');
      continue;
    }
    if (entry.hit != entry.found) {
      final missed = entry.found - entry.hit;
      failures.add(
        '$path is ${(entry.hit * 100 / entry.found).toStringAsFixed(1)}% '
        '($missed line${missed == 1 ? '' : 's'} uncovered) — the floor '
        'requires 100% here',
      );
    }
  }

  stdout.writeln(
    'overall: ${overall.toStringAsFixed(1)}% '
    '($totalHit/$totalFound lines, ${perFile.length} files)',
  );

  if (failures.isEmpty) {
    stdout.writeln('coverage thresholds met');
    return;
  }
  for (final failure in failures) {
    stderr.writeln('COVERAGE FAILURE: $failure');
  }
  exit(1);
}
