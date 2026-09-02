final RegExp _linePattern = RegExp(r'([^\r\n]*)(\r\n|\r|\n|$)');
final RegExp _levelTwoHeading = RegExp(r'^##[ \t]+');
final RegExp _unreleasedHeading = RegExp(r'^##[ \t]+Unreleased[ \t]*$');
final RegExp _sectionHeading = RegExp(r'^#{1,2}[ \t]+');
final RegExp _codeFence = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})');

/// Removes a whitespace-only first `Unreleased` section from a staged
/// changelog.
///
/// Populated draft sections remain unchanged.
String withoutEmptyLeadingUnreleasedSection(String source) {
  final List<Match> lines = _linePattern
      .allMatches(source)
      .where((Match line) => line.start != line.end)
      .toList(growable: false);
  final int firstSectionIndex = _firstLevelTwoSectionIndex(lines);
  if (firstSectionIndex < 0 ||
      !_unreleasedHeading.hasMatch(lines[firstSectionIndex].group(1)!)) {
    return source;
  }

  var nextContentIndex = firstSectionIndex + 1;
  while (nextContentIndex < lines.length &&
      lines[nextContentIndex].group(1)!.trim().isEmpty) {
    nextContentIndex += 1;
  }

  if (nextContentIndex == lines.length) {
    return source.replaceRange(
      lines[firstSectionIndex].start,
      source.length,
      '',
    );
  }
  if (!_sectionHeading.hasMatch(lines[nextContentIndex].group(1)!)) {
    return source;
  }

  return source.replaceRange(
    lines[firstSectionIndex].start,
    lines[nextContentIndex].start,
    '',
  );
}

int _firstLevelTwoSectionIndex(List<Match> lines) {
  String? openingFence;
  for (var index = 0; index < lines.length; index += 1) {
    final String line = lines[index].group(1)!;
    final Match? fenceMatch = _codeFence.firstMatch(line);
    if (openingFence != null) {
      if (fenceMatch != null &&
          _closesFence(fenceMatch.group(1)!, openingFence)) {
        openingFence = null;
      }
      continue;
    }
    if (fenceMatch != null) {
      openingFence = fenceMatch.group(1)!;
      continue;
    }
    if (_levelTwoHeading.hasMatch(line)) {
      return index;
    }
  }
  return -1;
}

bool _closesFence(String candidate, String openingFence) {
  return candidate.codeUnitAt(0) == openingFence.codeUnitAt(0) &&
      candidate.length >= openingFence.length;
}
