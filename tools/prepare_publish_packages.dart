import 'dart:io';

/// Creates an isolated Pub workspace for the two publishable packages.
///
/// The staged workspace intentionally excludes every `example` directory. It
/// is safe to run repeatedly: only the repository-local `publish` directory is
/// replaced after its path and type have been validated.
void main(List<String> arguments) {
  try {
    if (arguments.length == 1 && arguments.single == '--clean') {
      final Directory repositoryRoot = _findRepositoryRoot();
      final bool removed = _removeOutputDirectory(repositoryRoot);
      stdout.writeln(
        removed
            ? 'Removed isolated publication staging output.'
            : 'No publication staging output was present.',
      );
      return;
    }

    if (arguments.isNotEmpty) {
      throw _StagingException(
        'Use no arguments to stage packages or --clean to remove staging output.',
      );
    }

    final Directory repositoryRoot = _findRepositoryRoot();
    final Directory outputDirectory = _prepareOutputDirectory(repositoryRoot);

    for (final _PackageDefinition package in _packages) {
      _stagePackage(
        repositoryRoot: repositoryRoot,
        outputDirectory: outputDirectory,
        package: package,
      );
    }

    _writeWorkspaceManifest(outputDirectory);

    stdout.writeln(
      'Prepared isolated publication packages in '
      '${_displayPath(outputDirectory.path)}.',
    );
    for (final _PackageDefinition package in _packages) {
      stdout.writeln(
        '  ${package.name}: '
        '${_displayPath(_join(outputDirectory.path, package.stagingPath))}',
      );
    }
  } on _StagingException catch (error) {
    stderr.writeln('Publication staging failed: ${error.message}');
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln('Publication staging failed: ${error.message}');
    exitCode = 74;
  }
}

const List<_PackageDefinition> _packages = <_PackageDefinition>[
  _PackageDefinition(
    name: 'pulse_slab',
    sourcePath: 'packages/pulse_slab',
    stagingPath: 'packages/pulse_slab',
  ),
  _PackageDefinition(
    name: 'pulse_slab_flutter',
    sourcePath: 'packages/pulse_slab_flutter',
    stagingPath: 'packages/pulse_slab_flutter',
  ),
];

const Set<String> _publishableDirectoryNames = <String>{
  'assets',
  'benchmark',
  'doc',
  'docs',
  'lib',
  'test',
  'tool',
};

const Set<String> _publishableFileNames = <String>{
  '.gitignore',
  '.pubignore',
  'analysis_options.yaml',
  'authors',
  'changelog.md',
  'code_of_conduct.md',
  'contributing.md',
  'license',
  'notice',
  'pubspec.yaml',
  'readme.md',
};

const Set<String> _excludedDirectoryNames = <String>{
  '.dart_tool',
  '.git',
  '.idea',
  '.pub',
  '.vscode',
  'build',
  'coverage',
  'example',
};

const Set<String> _excludedFileNames = <String>{
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  '.metadata',
  'pubspec.lock',
  'pubspec_overrides.yaml',
};

Directory _findRepositoryRoot() {
  final File script = File.fromUri(Platform.script);
  if (!script.existsSync()) {
    throw const _StagingException('Cannot locate the staging tool file.');
  }

  final Directory toolDirectory = script.parent;
  if (_basename(toolDirectory.path) != 'tools') {
    throw const _StagingException(
      'The staging tool must remain in the repository tools directory.',
    );
  }

  final Directory repositoryRoot = Directory(
    toolDirectory.parent.resolveSymbolicLinksSync(),
  );
  final File workspaceManifest = File(
    _join(repositoryRoot.path, 'pubspec.yaml'),
  );
  if (!workspaceManifest.existsSync()) {
    throw const _StagingException(
      'The repository root does not contain a pubspec.yaml workspace manifest.',
    );
  }

  return repositoryRoot;
}

Directory _prepareOutputDirectory(Directory repositoryRoot) {
  _removeOutputDirectory(repositoryRoot);

  final String outputPath = _join(repositoryRoot.path, 'publish');
  final Directory outputDirectory = Directory(outputPath);
  outputDirectory.createSync(recursive: true);
  return outputDirectory;
}

bool _removeOutputDirectory(Directory repositoryRoot) {
  final String outputPath = _join(repositoryRoot.path, 'publish');
  _validateOutputPath(repositoryRoot: repositoryRoot, outputPath: outputPath);

  final FileSystemEntityType type = FileSystemEntity.typeSync(
    outputPath,
    followLinks: false,
  );
  switch (type) {
    case FileSystemEntityType.notFound:
      return false;
    case FileSystemEntityType.directory:
      final Directory outputDirectory = Directory(outputPath);
      _validateResolvedChildPath(
        repositoryRoot: repositoryRoot,
        candidatePath: outputDirectory.resolveSymbolicLinksSync(),
        description: 'existing publication output directory',
      );
      outputDirectory.deleteSync(recursive: true);
      return true;
    case FileSystemEntityType.link:
      throw const _StagingException(
        'Refusing to replace a symbolic link named publish.',
      );
    case FileSystemEntityType.file:
      throw const _StagingException(
        'Refusing to replace a file named publish.',
      );
    default:
      throw _StagingException(
        'Refusing to replace publication output with unsupported type $type.',
      );
  }
}

void _stagePackage({
  required Directory repositoryRoot,
  required Directory outputDirectory,
  required _PackageDefinition package,
}) {
  final Directory sourceDirectory = Directory(
    _join(repositoryRoot.path, package.sourcePath),
  );
  if (!sourceDirectory.existsSync()) {
    throw _StagingException(
      'Expected source package ${package.name} at ${package.sourcePath}.',
    );
  }
  _validateResolvedChildPath(
    repositoryRoot: repositoryRoot,
    candidatePath: sourceDirectory.resolveSymbolicLinksSync(),
    description: 'source package ${package.name}',
  );

  for (final String requiredFile in _requiredPackageFiles) {
    if (!File(_join(sourceDirectory.path, requiredFile)).existsSync()) {
      throw _StagingException(
        'Package ${package.name} is missing required file $requiredFile.',
      );
    }
  }

  final Directory destinationDirectory = Directory(
    _join(outputDirectory.path, package.stagingPath),
  );
  _validatePathWithin(
    parentDirectory: outputDirectory,
    candidatePath: destinationDirectory.path,
    description: 'staged package ${package.name}',
  );
  destinationDirectory.createSync(recursive: true);

  final List<FileSystemEntity> entries =
      sourceDirectory.listSync(followLinks: false)..sort(
        (FileSystemEntity left, FileSystemEntity right) =>
            left.path.compareTo(right.path),
      );

  for (final FileSystemEntity entry in entries) {
    final String name = _basename(entry.path);
    final String normalizedName = name.toLowerCase();
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      entry.path,
      followLinks: false,
    );

    if (type == FileSystemEntityType.link) {
      throw _StagingException(
        'Refusing to stage symbolic link ${_displayPath(entry.path)}.',
      );
    }

    if (type == FileSystemEntityType.directory) {
      if (_excludedDirectoryNames.contains(normalizedName)) {
        continue;
      }
      if (_publishableDirectoryNames.contains(normalizedName)) {
        _copyDirectory(
          source: Directory(entry.path),
          destination: Directory(_join(destinationDirectory.path, name)),
        );
      }
      continue;
    }

    if (type == FileSystemEntityType.file &&
        _publishableFileNames.contains(normalizedName)) {
      final File destination = File(_join(destinationDirectory.path, name));
      if (normalizedName == 'pubspec.yaml') {
        destination.writeAsStringSync(
          _withoutNestedWorkspace(File(entry.path)),
        );
      } else {
        File(entry.path).copySync(destination.path);
      }
    }
  }

  final File stagedManifest = File(
    _join(destinationDirectory.path, 'pubspec.yaml'),
  );
  if (!stagedManifest.existsSync()) {
    throw _StagingException(
      'Failed to stage pubspec.yaml for ${package.name}.',
    );
  }
  _validateWorkspaceResolution(stagedManifest, package.name);
}

const List<String> _requiredPackageFiles = <String>[
  'pubspec.yaml',
  'README.md',
  'CHANGELOG.md',
  'LICENSE',
];

void _copyDirectory({
  required Directory source,
  required Directory destination,
}) {
  destination.createSync(recursive: true);
  final List<FileSystemEntity> entries = source.listSync(followLinks: false)
    ..sort(
      (FileSystemEntity left, FileSystemEntity right) =>
          left.path.compareTo(right.path),
    );

  for (final FileSystemEntity entry in entries) {
    final String name = _basename(entry.path);
    final String normalizedName = name.toLowerCase();
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      entry.path,
      followLinks: false,
    );

    if (type == FileSystemEntityType.link) {
      throw _StagingException(
        'Refusing to stage symbolic link ${_displayPath(entry.path)}.',
      );
    }
    if (type == FileSystemEntityType.directory) {
      if (_excludedDirectoryNames.contains(normalizedName)) {
        continue;
      }
      _copyDirectory(
        source: Directory(entry.path),
        destination: Directory(_join(destination.path, name)),
      );
      continue;
    }
    if (type == FileSystemEntityType.file &&
        !_excludedFileNames.contains(normalizedName)) {
      File(entry.path).copySync(_join(destination.path, name));
    }
  }
}

String _withoutNestedWorkspace(File sourceManifest) {
  final String normalizedSource = sourceManifest
      .readAsStringSync()
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final List<String> sourceLines = normalizedSource.split('\n');
  final List<String> outputLines = <String>[];
  var removedWorkspace = false;

  for (var index = 0; index < sourceLines.length;) {
    final String line = sourceLines[index];
    if (!RegExp(r'^workspace\s*:').hasMatch(line)) {
      outputLines.add(line);
      index += 1;
      continue;
    }

    removedWorkspace = true;
    index += 1;
    while (index < sourceLines.length &&
        _isPartOfTopLevelYamlBlock(sourceLines[index])) {
      index += 1;
    }
  }

  if (!removedWorkspace) {
    return normalizedSource;
  }

  return '${outputLines.join('\n').trimRight()}\n';
}

bool _isPartOfTopLevelYamlBlock(String line) {
  final String trimmed = line.trim();
  return line.startsWith(' ') ||
      line.startsWith('\t') ||
      trimmed.isEmpty ||
      trimmed.startsWith('#');
}

void _validateWorkspaceResolution(File stagedManifest, String packageName) {
  final String contents = stagedManifest.readAsStringSync();
  if (!RegExp(
    r'^resolution\s*:\s*workspace\s*$',
    multiLine: true,
  ).hasMatch(contents)) {
    throw _StagingException(
      'Staged package $packageName must use resolution: workspace.',
    );
  }
  if (RegExp(r'^workspace\s*:', multiLine: true).hasMatch(contents)) {
    throw _StagingException(
      'Staged package $packageName still declares a nested workspace.',
    );
  }
}

void _writeWorkspaceManifest(Directory outputDirectory) {
  final File manifest = File(_join(outputDirectory.path, 'pubspec.yaml'));
  manifest.writeAsStringSync('''name: pulse_slab_publish_workspace
description: Isolated publication staging workspace for the pulse_slab package family.
publish_to: none

environment:
  sdk: '>=3.6.0 <4.0.0'

workspace:
  - packages/pulse_slab
  - packages/pulse_slab_flutter
''');
}

void _validateOutputPath({
  required Directory repositoryRoot,
  required String outputPath,
}) {
  final String normalizedRoot = _normalizePath(repositoryRoot.absolute.path);
  final String normalizedOutput = _normalizePath(
    Directory(outputPath).absolute.path,
  );
  final String expectedPath = _normalizePath(_join(normalizedRoot, 'publish'));

  if (normalizedOutput != expectedPath) {
    throw _StagingException(
      'The publication output directory must be the repository-local publish directory.',
    );
  }
}

void _validatePathWithin({
  required Directory parentDirectory,
  required String candidatePath,
  required String description,
}) {
  final String normalizedParent = _normalizePath(parentDirectory.absolute.path);
  final String normalizedCandidate = _normalizePath(
    Directory(candidatePath).absolute.path,
  );
  if (!_isPathWithin(normalizedParent, normalizedCandidate)) {
    throw _StagingException(
      'The $description must be inside the expected staging directory.',
    );
  }
}

void _validateResolvedChildPath({
  required Directory repositoryRoot,
  required String candidatePath,
  required String description,
}) {
  final String normalizedRoot = _normalizePath(
    repositoryRoot.resolveSymbolicLinksSync(),
  );
  final String normalizedCandidate = _normalizePath(candidatePath);
  if (!_isPathWithin(normalizedRoot, normalizedCandidate)) {
    throw _StagingException(
      'The resolved $description escapes the expected repository directory.',
    );
  }
}

bool _isPathWithin(String parentPath, String candidatePath) {
  final String prefix = parentPath.endsWith(Platform.pathSeparator)
      ? parentPath
      : '$parentPath${Platform.pathSeparator}';
  return candidatePath.startsWith(prefix);
}

String _normalizePath(String path) {
  final String normalized = path.replaceAll('/', Platform.pathSeparator);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String _join(String left, String right) {
  return '$left${Platform.pathSeparator}$right';
}

String _basename(String path) {
  final int forwardSlash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf('\\');
  final int separator = forwardSlash > backslash ? forwardSlash : backslash;
  return path.substring(separator + 1);
}

String _displayPath(String path) {
  return path.replaceAll('\\', '/');
}

final class _PackageDefinition {
  const _PackageDefinition({
    required this.name,
    required this.sourcePath,
    required this.stagingPath,
  });

  final String name;
  final String sourcePath;
  final String stagingPath;
}

final class _StagingException implements Exception {
  const _StagingException(this.message);

  final String message;
}
