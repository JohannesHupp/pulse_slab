import 'src/publish_changelog.dart';

void main() {
  _expectTransformation(
    description: 'removes an empty leading section while preserving CRLF',
    source:
        '# Changelog\r\n'
        '\r\n'
        '## Unreleased\r\n'
        ' \t\r\n'
        '## 0.1.0-beta.3\r\n',
    expected: '# Changelog\r\n\r\n## 0.1.0-beta.3\r\n',
  );
  _expectTransformation(
    description: 'removes an empty leading section through end of file',
    source: '# Changelog\n## Unreleased',
    expected: '# Changelog\n',
  );
  _expectTransformation(
    description: 'preserves a populated leading draft section',
    source:
        '# Changelog\n'
        '\n'
        '## Unreleased\n'
        '\n'
        '- Keep this draft entry.\n'
        '\n'
        '## 0.1.0-beta.3\n',
    expected:
        '# Changelog\n'
        '\n'
        '## Unreleased\n'
        '\n'
        '- Keep this draft entry.\n'
        '\n'
        '## 0.1.0-beta.3\n',
  );
  _expectTransformation(
    description: 'preserves a later Unreleased section',
    source:
        '# Changelog\n'
        '\n'
        '## 0.1.0-beta.3\n'
        '\n'
        '## Unreleased\n',
    expected:
        '# Changelog\n'
        '\n'
        '## 0.1.0-beta.3\n'
        '\n'
        '## Unreleased\n',
  );
  _expectTransformation(
    description: 'ignores headings in fenced code blocks',
    source:
        '# Changelog\n'
        '\n'
        '```dart\n'
        "const heading = '## Unreleased';\n"
        '## Unreleased\n'
        '```\n'
        '\n'
        '## 0.1.0-beta.3\n',
    expected:
        '# Changelog\n'
        '\n'
        '```dart\n'
        "const heading = '## Unreleased';\n"
        '## Unreleased\n'
        '```\n'
        '\n'
        '## 0.1.0-beta.3\n',
  );
  _expectTransformation(
    description: 'preserves a valid changelog without a final newline',
    source: '# Changelog\n\n## 0.1.0-beta.3',
    expected: '# Changelog\n\n## 0.1.0-beta.3',
  );
  print('Publication changelog staging tests passed.');
}

void _expectTransformation({
  required String description,
  required String source,
  required String expected,
}) {
  final String actual = withoutEmptyLeadingUnreleasedSection(source);
  if (actual == expected) {
    return;
  }
  throw StateError(
    '$description produced an unexpected staged changelog.\n'
    'Expected: $expected\n'
    'Actual: $actual',
  );
}
