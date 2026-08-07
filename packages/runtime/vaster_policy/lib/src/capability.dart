import 'policy_action.dart';
import 'resource_pattern.dart';

/// Permission token binding a [PolicyAction] to a strongly-typed [ResourcePattern].
class Capability {
  final PolicyAction action;
  final ResourcePattern pattern;

  const Capability({required this.action, required this.pattern});

  /// Factory helper for exact resource capability.
  factory Capability.exact(PolicyAction action, String value) =>
      Capability(action: action, pattern: ExactResourcePattern(value));

  /// Factory helper for glob resource capability.
  factory Capability.glob(PolicyAction action, String globPattern) =>
      Capability(action: action, pattern: PathGlobResourcePattern(globPattern));

  /// Factory helper for prefix resource capability.
  factory Capability.prefix(PolicyAction action, String prefix) =>
      Capability(action: action, pattern: PrefixResourcePattern(prefix));

  /// Factory helper for wildcard capability matching any resource.
  factory Capability.any(PolicyAction action) =>
      Capability(action: action, pattern: const AnyResourcePattern());

  /// Returns `true` if this capability authorizes [action] on [resource].
  bool matches(PolicyAction action, String resource) {
    return this.action == action && pattern.matches(resource);
  }

  Map<String, dynamic> toJson() => {'action': action.name, 'pattern': pattern.toJson()};

  factory Capability.fromJson(Map<String, dynamic> json) {
    return Capability(
      action: PolicyAction.parse(json['action'] as String? ?? ''),
      pattern: ResourcePattern.fromJson(json['pattern'] as Map<String, dynamic>? ?? {}),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Capability && other.action == action && other.pattern == pattern;

  @override
  int get hashCode => Object.hash(action, pattern);

  @override
  String toString() => 'Capability($action, $pattern)';
}
