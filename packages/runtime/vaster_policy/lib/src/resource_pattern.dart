/// Strongly-typed sealed hierarchy representing resource matching patterns.
sealed class ResourcePattern {
  const ResourcePattern();

  /// Returns `true` if this pattern matches the given [resource] target.
  bool matches(String resource);

  /// Serializes pattern to JSON.
  Map<String, dynamic> toJson();

  /// Deserializes pattern from JSON.
  factory ResourcePattern.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? 'exact';
    return switch (type) {
      'exact' => ExactResourcePattern(json['value'] as String? ?? ''),
      'glob' => PathGlobResourcePattern(json['globPattern'] as String? ?? ''),
      'prefix' => PrefixResourcePattern(json['prefix'] as String? ?? ''),
      'any' => const AnyResourcePattern(),
      _ => ExactResourcePattern(json['value'] as String? ?? ''),
    };
  }
}

/// Matches exact string equality (e.g. '/mem/config.json', 'exec_dart').
final class ExactResourcePattern extends ResourcePattern {
  final String value;

  const ExactResourcePattern(this.value);

  @override
  bool matches(String resource) => resource == value;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'exact',
        'value': value,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExactResourcePattern && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Exact("$value")';
}

/// Matches filesystem path globs (e.g. '/mem/src/**', '/mem/*.txt').
final class PathGlobResourcePattern extends ResourcePattern {
  final String globPattern;

  const PathGlobResourcePattern(this.globPattern);

  @override
  bool matches(String resource) {
    final regexPattern = _globToRegex(globPattern);
    final regex = RegExp('^$regexPattern\$');
    return regex.hasMatch(resource);
  }

  static String _globToRegex(String glob) {
    final sb = StringBuffer();
    int i = 0;
    while (i < glob.length) {
      final char = glob[i];
      if (char == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          sb.write('.*');
          i += 2;
          // Skip trailing slash if present e.g. "/**/"
          if (i < glob.length && glob[i] == '/') {
            i++;
          }
          continue;
        } else {
          sb.write('[^/]*');
          i++;
          continue;
        }
      } else if (r'.^$()+{}[]\|?'.contains(char)) {
        sb.write('\\$char');
      } else {
        sb.write(char);
      }
      i++;
    }
    return sb.toString();
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'glob',
        'globPattern': globPattern,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PathGlobResourcePattern && other.globPattern == globPattern;

  @override
  int get hashCode => globPattern.hashCode;

  @override
  String toString() => 'Glob("$globPattern")';
}

/// Matches string prefix (e.g. 'tool_git_').
final class PrefixResourcePattern extends ResourcePattern {
  final String prefix;

  const PrefixResourcePattern(this.prefix);

  @override
  bool matches(String resource) => resource.startsWith(prefix);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'prefix',
        'prefix': prefix,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrefixResourcePattern && other.prefix == prefix;

  @override
  int get hashCode => prefix.hashCode;

  @override
  String toString() => 'Prefix("$prefix")';
}

/// Matches any resource (wildcard '*').
final class AnyResourcePattern extends ResourcePattern {
  const AnyResourcePattern();

  @override
  bool matches(String resource) => true;

  @override
  Map<String, dynamic> toJson() => {'type': 'any'};

  @override
  bool operator ==(Object other) => identical(this, other) || other is AnyResourcePattern;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'Any(*)';
}
