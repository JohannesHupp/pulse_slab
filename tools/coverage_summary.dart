/// Builds a compact GitHub Markdown coverage table from one or more LCOV
/// reports.
///
/// This tool deliberately has no package dependencies so it can run in a
/// GitHub Actions job before any package-specific tooling is available.
///
/// Example:
/// ```sh
/// dart run tools/coverage_summary.dart \
///   --input pulse_slab=packages/pulse_slab/coverage/lcov.info \
///   --input pulse_slab_flutter=packages/pulse_slab_flutter/coverage/lcov.info \
///   --output coverage/summary.md
/// ```
///
/// Omit [--output] to write the Markdown table to standard output.
import 'dart:io';

const String _toolName = 'coverage_summary';
const String _usage = '''Usage:
  dart run tools/coverage_summary.dart \\
    --input <package-name=lcov-file> [--input <package-name=lcov-file> ...] \\
    [--output <markdown-file>]

Options:
  --input   A package label and an LCOV report path separated by one equals sign.
            Repeat this option for every package to include in the table.
  --output  Write Markdown to this file. Its parent directories are created when
            needed. Omit this option to write Markdown to standard output.
  --help    Show this help text.

Example:
  dart run tools/coverage_summary.dart \\
    --input pulse_slab=packages/pulse_slab/coverage/lcov.info \\
    --input pulse_slab_flutter=packages/pulse_slab_flutter/coverage/lcov.info \\
    --output coverage/summary.md
''';

/// Runs the command-line LCOV summarizer.
Future<void> main(List<String> arguments) async {
  try {
    final _CommandOptions options = _parseArguments(arguments);
    if (options.showHelp) {
      stdout.write(_usage);
      return;
    }

    final List<_PackageCoverage> packageCoverage = <_PackageCoverage>[];
    for (final _InputSpec input in options.inputs) {
      final _CoverageMetrics metrics = await _LcovReader(input).read();
      packageCoverage.add(_PackageCoverage(input.label, metrics));
    }

    final String markdown = _renderMarkdown(packageCoverage);
    final String? outputPath = options.outputPath;
    if (outputPath == null) {
      stdout.write(markdown);
      return;
    }

    await _writeOutput(outputPath, markdown, options.inputs);
  } on _UsageException catch (error) {
    stderr.writeln('$_toolName: ${error.message}');
    stderr.write(_usage);
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln('$_toolName: ${error.message}');
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('$_toolName: ${error.message}');
    exitCode = 1;
  }
}

_CommandOptions _parseArguments(List<String> arguments) {
  final List<_InputSpec> inputs = <_InputSpec>[];
  String? outputPath;
  bool showHelp = false;

  for (int index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (argument == '--help') {
      showHelp = true;
      continue;
    }

    if (argument == '--input' || argument.startsWith('--input=')) {
      final String value;
      if (argument == '--input') {
        if (index + 1 >= arguments.length) {
          throw const _UsageException('Missing a value after --input.');
        }
        value = arguments[++index];
      } else {
        value = argument.substring('--input='.length);
      }
      inputs.add(_parseInput(value));
      continue;
    }

    if (argument == '--output' || argument.startsWith('--output=')) {
      if (outputPath != null) {
        throw const _UsageException('--output may only be supplied once.');
      }
      if (argument == '--output') {
        if (index + 1 >= arguments.length) {
          throw const _UsageException('Missing a value after --output.');
        }
        outputPath = arguments[++index];
      } else {
        outputPath = argument.substring('--output='.length);
      }
      if (outputPath.isEmpty) {
        throw const _UsageException('The --output path must not be empty.');
      }
      continue;
    }

    throw _UsageException('Unknown argument "$argument".');
  }

  if (showHelp) {
    if (arguments.length != 1) {
      throw const _UsageException(
        '--help cannot be combined with other options.',
      );
    }
    return const _CommandOptions(showHelp: true);
  }

  if (inputs.isEmpty) {
    throw const _UsageException('At least one --input option is required.');
  }

  final Set<String> labels = <String>{};
  for (final _InputSpec input in inputs) {
    if (!labels.add(input.label.toLowerCase())) {
      throw _UsageException(
        'The package label "${input.label}" was supplied more than once.',
      );
    }
  }

  return _CommandOptions(inputs: inputs, outputPath: outputPath);
}

_InputSpec _parseInput(String value) {
  final int separator = value.indexOf('=');
  if (separator <= 0 || separator == value.length - 1) {
    throw const _UsageException(
      'Each --input value must use the form <package-name=lcov-file>.',
    );
  }

  final String label = value.substring(0, separator);
  final String path = value.substring(separator + 1);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(label)) {
    throw _UsageException(
      'The package label "$label" may contain only letters, digits, dots, hyphens, and underscores.',
    );
  }
  if (path.trim().isEmpty) {
    throw const _UsageException('An LCOV input path must not be empty.');
  }

  return _InputSpec(label, path);
}

Future<void> _writeOutput(
  String outputPath,
  String markdown,
  List<_InputSpec> inputs,
) async {
  final File output = File(outputPath);
  final String normalizedOutputPath = _normalizedPath(output);
  for (final _InputSpec input in inputs) {
    if (_normalizedPath(File(input.path)) == normalizedOutputPath) {
      throw _UsageException(
        'The output file must not overwrite an LCOV input file.',
      );
    }
  }

  final FileSystemEntityType existingType = await FileSystemEntity.type(
    output.path,
    followLinks: true,
  );
  if (existingType == FileSystemEntityType.directory) {
    throw _UsageException(
      'The --output path points to a directory: ${output.path}',
    );
  }

  await output.parent.create(recursive: true);
  await output.writeAsString(markdown, flush: true);
}

String _normalizedPath(File file) {
  final String absolutePath = file.absolute.path;
  return Platform.isWindows ? absolutePath.toLowerCase() : absolutePath;
}

String _renderMarkdown(List<_PackageCoverage> packageCoverage) {
  final _CoverageMetrics total = _CoverageMetrics.combine(
    packageCoverage.map((_PackageCoverage entry) => entry.metrics),
  );
  final StringBuffer buffer = StringBuffer()
    ..writeln('## Code coverage')
    ..writeln()
    ..writeln(
      '| Package | Lines hit | Lines found | Line coverage | Branches hit | Branches found | Branch coverage |',
    )
    ..writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: |');

  for (final _PackageCoverage entry in packageCoverage) {
    buffer.writeln(_tableRow(entry.label, entry.metrics));
  }
  buffer.writeln(_tableRow('**Total**', total));

  return buffer.toString();
}

String _tableRow(String label, _CoverageMetrics metrics) {
  return '| $label | ${metrics.lineHit} | ${metrics.lineFound} | '
      '${metrics.lineCoverage} | ${metrics.branchHit} | '
      '${metrics.branchFound} | ${metrics.branchCoverage} |';
}

final class _LcovReader {
  _LcovReader(this.input);

  final _InputSpec input;

  Future<_CoverageMetrics> read() async {
    final File file = File(input.path);
    final FileSystemEntityType type = await FileSystemEntity.type(
      file.path,
      followLinks: true,
    );
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('LCOV input file was not found.', file.path);
    }

    final String contents = await file.readAsString();
    final Map<String, _MergedSourceCoverage> coverageBySource =
        <String, _MergedSourceCoverage>{};
    _SourceRecord? record;
    final List<String> lines = contents.split(RegExp(r'\r?\n'));

    for (int index = 0; index < lines.length; index++) {
      String line = lines[index].trim();
      final int lineNumber = index + 1;
      if (index == 0 && line.startsWith('\uFEFF')) {
        line = line.substring(1);
      }
      if (line.isEmpty) {
        continue;
      }

      if (line == 'end_of_record') {
        final _SourceRecord? activeRecord = record;
        if (activeRecord == null) {
          throw _formatError(
            lineNumber,
            'Found end_of_record without a preceding SF record.',
          );
        }
        final _SourceRecord finishedRecord = activeRecord;
        finishedRecord.validate(lineNumber);
        final _MergedSourceCoverage merged = coverageBySource.putIfAbsent(
          finishedRecord.sourcePath,
          () => _MergedSourceCoverage(),
        );
        merged.merge(finishedRecord);
        record = null;
        continue;
      }

      final int separator = line.indexOf(':');
      if (separator <= 0) {
        throw _formatError(
          lineNumber,
          'Expected an LCOV tag followed by a colon.',
        );
      }
      final String tag = line.substring(0, separator);
      final String value = line.substring(separator + 1);

      switch (tag) {
        case 'TN':
          if (record != null) {
            throw _formatError(
              lineNumber,
              'TN must appear before SF in a record.',
            );
          }
          break;
        case 'SF':
          if (record != null) {
            throw _formatError(
              lineNumber,
              'A record must end with end_of_record before another SF tag.',
            );
          }
          if (value.trim().isEmpty) {
            throw _formatError(
              lineNumber,
              'SF must include a non-empty source path.',
            );
          }
          record = _SourceRecord(value);
          break;
        case 'DA':
          _requireRecord(record, lineNumber).addLine(value, lineNumber);
          break;
        case 'BRDA':
          _requireRecord(record, lineNumber).addBranch(value, lineNumber);
          break;
        case 'FN':
          _requireRecord(record, lineNumber).addFunction(value, lineNumber);
          break;
        case 'FNDA':
          _requireRecord(record, lineNumber).addFunctionHit(value, lineNumber);
          break;
        case 'LF':
        case 'LH':
        case 'BRF':
        case 'BRH':
        case 'FNF':
        case 'FNH':
          _requireRecord(
            record,
            lineNumber,
          ).addDeclaredTotal(tag, value, lineNumber);
          break;
        case 'VER':
          if (value.trim().isEmpty) {
            throw _formatError(
              lineNumber,
              'VER must include a non-empty value.',
            );
          }
          _requireRecord(record, lineNumber);
          break;
        default:
          throw _formatError(lineNumber, 'Unsupported LCOV tag "$tag".');
      }
    }

    if (record != null) {
      throw FormatException(
        '${input.path}: The final SF record is missing end_of_record.',
      );
    }
    if (coverageBySource.isEmpty) {
      throw FormatException(
        '${input.path}: No SF coverage records were found.',
      );
    }

    return _CoverageMetrics.fromSources(coverageBySource.values);
  }

  _SourceRecord _requireRecord(_SourceRecord? record, int lineNumber) {
    if (record == null) {
      throw _formatError(
        lineNumber,
        'A source-specific tag must follow an SF tag.',
      );
    }
    return record;
  }

  FormatException _formatError(int lineNumber, String message) {
    return FormatException('${input.path}:$lineNumber: $message');
  }
}

final class _SourceRecord {
  _SourceRecord(this.sourcePath);

  final String sourcePath;
  final Map<int, int> lineHits = <int, int>{};
  final Map<String, int?> branchHits = <String, int?>{};
  final Map<String, int> declaredTotals = <String, int>{};
  final Map<String, int> functions = <String, int>{};
  final Map<String, int> functionHits = <String, int>{};

  void addLine(String value, int lineNumber) {
    final List<String> parts = value.split(',');
    if (parts.length < 2 || parts.length > 3) {
      throw _recordError(
        lineNumber,
        'DA must use DA:<line>,<hit-count>[,<checksum>].',
      );
    }
    final int line = _positiveInteger(parts[0], lineNumber, 'DA line number');
    final int hits = _nonNegativeInteger(parts[1], lineNumber, 'DA hit count');
    if (parts.length == 3 && parts[2].isEmpty) {
      throw _recordError(
        lineNumber,
        'DA checksums must not be empty when present.',
      );
    }
    _addMaximum(lineHits, line, hits, lineNumber, 'DA line number');
  }

  void addBranch(String value, int lineNumber) {
    final List<String> parts = value.split(',');
    if (parts.length != 4) {
      throw _recordError(
        lineNumber,
        'BRDA must use BRDA:<line>,<block>,<branch>,<taken-count-or-dash>.',
      );
    }
    final int line = _positiveInteger(parts[0], lineNumber, 'BRDA line number');
    final int block = _nonNegativeInteger(
      parts[1],
      lineNumber,
      'BRDA block number',
    );
    final int branch = _nonNegativeInteger(
      parts[2],
      lineNumber,
      'BRDA branch number',
    );
    final int? hits = parts[3] == '-'
        ? null
        : _nonNegativeInteger(parts[3], lineNumber, 'BRDA taken count');
    final String key = '$line:$block:$branch';
    final int? current = branchHits[key];
    if (current == null || hits == null) {
      branchHits[key] = hits ?? current;
      return;
    }
    branchHits[key] = hits > current ? hits : current;
  }

  void addFunction(String value, int lineNumber) {
    final int separator = value.indexOf(',');
    if (separator <= 0 || separator == value.length - 1) {
      throw _recordError(lineNumber, 'FN must use FN:<line>,<function-name>.');
    }
    final int line = _positiveInteger(
      value.substring(0, separator),
      lineNumber,
      'FN line number',
    );
    final String name = value.substring(separator + 1);
    if (name.trim().isEmpty) {
      throw _recordError(lineNumber, 'FN function names must not be empty.');
    }
    final String key = '$line:$name';
    if (functions.containsKey(key)) {
      throw _recordError(
        lineNumber,
        'FN declares function "$name" more than once.',
      );
    }
    functions[key] = line;
  }

  void addFunctionHit(String value, int lineNumber) {
    final int separator = value.indexOf(',');
    if (separator <= 0 || separator == value.length - 1) {
      throw _recordError(
        lineNumber,
        'FNDA must use FNDA:<hit-count>,<function-name>.',
      );
    }
    final int hits = _nonNegativeInteger(
      value.substring(0, separator),
      lineNumber,
      'FNDA hit count',
    );
    final String name = value.substring(separator + 1);
    if (name.trim().isEmpty) {
      throw _recordError(lineNumber, 'FNDA function names must not be empty.');
    }
    _addMaximum(functionHits, name, hits, lineNumber, 'FNDA function name');
  }

  void addDeclaredTotal(String tag, String value, int lineNumber) {
    if (declaredTotals.containsKey(tag)) {
      throw _recordError(lineNumber, '$tag may only appear once in a record.');
    }
    declaredTotals[tag] = _nonNegativeInteger(value, lineNumber, '$tag total');
  }

  void validate(int lineNumber) {
    _validateTotalPair('LH', 'LF', lineNumber);
    _validateTotalPair('BRH', 'BRF', lineNumber);
    _validateTotalPair('FNH', 'FNF', lineNumber);
    _validateLineTotals(lineNumber);
    _validateBranchTotals(lineNumber);
  }

  void _validateTotalPair(String hitTag, String foundTag, int lineNumber) {
    final int? hits = declaredTotals[hitTag];
    final int? found = declaredTotals[foundTag];
    if ((hits == null) != (found == null)) {
      throw _recordError(
        lineNumber,
        '$hitTag and $foundTag must either both be present or both be absent.',
      );
    }
    if (hits != null && hits > found!) {
      throw _recordError(
        lineNumber,
        '$hitTag must not be greater than $foundTag.',
      );
    }
  }

  void _validateLineTotals(int lineNumber) {
    final int? declaredFound = declaredTotals['LF'];
    if (declaredFound == null) {
      return;
    }
    final int actualFound = lineHits.length;
    final int actualHit = lineHits.values.where((int hits) => hits > 0).length;
    if (declaredFound != actualFound || declaredTotals['LH'] != actualHit) {
      throw _recordError(
        lineNumber,
        'LF/LH do not match the DA entries in this record.',
      );
    }
  }

  void _validateBranchTotals(int lineNumber) {
    final int? declaredFound = declaredTotals['BRF'];
    if (declaredFound == null) {
      return;
    }
    final int actualFound = branchHits.length;
    final int actualHit = branchHits.values
        .where((int? hits) => hits != null && hits > 0)
        .length;
    if (declaredFound != actualFound || declaredTotals['BRH'] != actualHit) {
      throw _recordError(
        lineNumber,
        'BRF/BRH do not match the BRDA entries in this record.',
      );
    }
  }

  void _addMaximum<K>(
    Map<K, int> values,
    K key,
    int value,
    int lineNumber,
    String description,
  ) {
    final int? existing = values[key];
    if (existing == null) {
      values[key] = value;
      return;
    }
    if (value < existing) {
      throw _recordError(
        lineNumber,
        '$description was repeated with a lower hit count.',
      );
    }
    values[key] = value;
  }

  int _positiveInteger(String value, int lineNumber, String description) {
    final int parsed = _nonNegativeInteger(value, lineNumber, description);
    if (parsed == 0) {
      throw _recordError(lineNumber, '$description must be greater than zero.');
    }
    return parsed;
  }

  int _nonNegativeInteger(String value, int lineNumber, String description) {
    final int? parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      throw _recordError(
        lineNumber,
        '$description must be a non-negative integer.',
      );
    }
    return parsed;
  }

  FormatException _recordError(int lineNumber, String message) {
    return FormatException('$sourcePath:$lineNumber: $message');
  }
}

final class _MergedSourceCoverage {
  final Map<int, int> lineHits = <int, int>{};
  final Map<String, int?> branchHits = <String, int?>{};

  void merge(_SourceRecord record) {
    for (final MapEntry<int, int> entry in record.lineHits.entries) {
      final int? current = lineHits[entry.key];
      if (current == null || entry.value > current) {
        lineHits[entry.key] = entry.value;
      }
    }
    for (final MapEntry<String, int?> entry in record.branchHits.entries) {
      final int? current = branchHits[entry.key];
      final int? next = entry.value;
      if (current == null || next == null) {
        branchHits[entry.key] = next ?? current;
      } else if (next > current) {
        branchHits[entry.key] = next;
      }
    }
  }
}

final class _CoverageMetrics {
  const _CoverageMetrics({
    required this.lineFound,
    required this.lineHit,
    required this.branchFound,
    required this.branchHit,
  });

  final int lineFound;
  final int lineHit;
  final int branchFound;
  final int branchHit;

  String get lineCoverage => _formatPercentage(lineHit, lineFound);

  String get branchCoverage => _formatPercentage(branchHit, branchFound);

  static _CoverageMetrics fromSources(Iterable<_MergedSourceCoverage> sources) {
    int lineFound = 0;
    int lineHit = 0;
    int branchFound = 0;
    int branchHit = 0;

    for (final _MergedSourceCoverage source in sources) {
      lineFound += source.lineHits.length;
      lineHit += source.lineHits.values.where((int hits) => hits > 0).length;
      branchFound += source.branchHits.length;
      branchHit += source.branchHits.values
          .where((int? hits) => hits != null && hits > 0)
          .length;
    }

    return _CoverageMetrics(
      lineFound: lineFound,
      lineHit: lineHit,
      branchFound: branchFound,
      branchHit: branchHit,
    );
  }

  static _CoverageMetrics combine(Iterable<_CoverageMetrics> metrics) {
    int lineFound = 0;
    int lineHit = 0;
    int branchFound = 0;
    int branchHit = 0;

    for (final _CoverageMetrics value in metrics) {
      lineFound += value.lineFound;
      lineHit += value.lineHit;
      branchFound += value.branchFound;
      branchHit += value.branchHit;
    }

    return _CoverageMetrics(
      lineFound: lineFound,
      lineHit: lineHit,
      branchFound: branchFound,
      branchHit: branchHit,
    );
  }
}

String _formatPercentage(int hit, int found) {
  if (found == 0) {
    return 'N/A';
  }
  return '${(hit * 100 / found).toStringAsFixed(2)}%';
}

final class _InputSpec {
  const _InputSpec(this.label, this.path);

  final String label;
  final String path;
}

final class _PackageCoverage {
  const _PackageCoverage(this.label, this.metrics);

  final String label;
  final _CoverageMetrics metrics;
}

final class _CommandOptions {
  const _CommandOptions({
    this.inputs = const <_InputSpec>[],
    this.outputPath,
    this.showHelp = false,
  });

  final List<_InputSpec> inputs;
  final String? outputPath;
  final bool showHelp;
}

final class _UsageException implements Exception {
  const _UsageException(this.message);

  final String message;
}
