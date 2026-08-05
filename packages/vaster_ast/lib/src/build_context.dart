part of 'ast_lib.dart';

/// Container for active tool definitions in BuildContext.
final class ToolSetData {
  final List<ToolDefinition> tools;
  const ToolSetData(this.tools);
}

/// Context passed during AST expansion and compilation.
///
/// Carries pipeline-level configuration, environment properties, and typed
/// values injected by [Provider]s. Use [read<T>()] or [tryRead<T>()] to
/// retrieve typed values injected by ancestor [Provider]s.
class BuildContext {
  /// The top-level pipeline specification.
  final PipelineSpec pipelineSpec;

  /// Currently registered agent roles (roleId -> AgentRole).
  final Map<String, AgentRole> roles;

  /// Currently registered storage mounts (mountPrefix -> StorageMount).
  final Map<String, StorageMount> mounts;

  /// Currently registered code environments (envId -> CodeEnvironment).
  final Map<String, CodeEnvironment> environments;

  /// Untyped string-keyed properties.
  final Map<String, dynamic> properties;

  /// Typed values injected by ancestor [Provider]s.
  final Map<Type, dynamic> typedValues;

  const BuildContext({
    required this.pipelineSpec,
    this.roles = const {},
    this.mounts = const {},
    this.environments = const {},
    this.properties = const {},
    this.typedValues = const {},
  });

  // ──────────────────────────────────────────────
  // Typed Provider API
  // ──────────────────────────────────────────────

  /// Reads a typed value of [T] injected by an ancestor [Provider].
  ///
  /// Throws [StateError] if no value of type [T] has been provided.
  T read<T>() {
    final value = typedValues[T];
    if (value == null) {
      throw StateError(
        'No value of type $T found in BuildContext. '
        'Wrap the node tree with Provider<$T>(...) to inject it.',
      );
    }
    return value as T;
  }

  /// Declarative alias for [read<T>] to retrieve contextual data.
  T get<T>([String? key]) {
    if (key != null && properties.containsKey(key)) {
      return properties[key] as T;
    }
    return read<T>();
  }

  /// Reads a typed value of [T] or returns `null` if not provided.
  T? tryRead<T>() => typedValues[T] as T?;

  /// Returns `true` if a value of type [T] has been provided.
  bool has<T>() => typedValues.containsKey(T);

  /// Returns a new [BuildContext] with [value] of type [T] injected.
  BuildContext provide<T>(T value) => BuildContext(
        pipelineSpec: pipelineSpec,
        roles: roles,
        mounts: mounts,
        environments: environments,
        properties: properties,
        typedValues: {...typedValues, T: value},
      );

  // ──────────────────────────────────────────────
  // Structural Context Helpers
  // ──────────────────────────────────────────────

  /// Returns a copy with a string-keyed property added.
  BuildContext withProperty(String key, dynamic value) => BuildContext(
        pipelineSpec: pipelineSpec,
        roles: roles,
        mounts: mounts,
        environments: environments,
        properties: {...properties, key: value},
        typedValues: typedValues,
      );

  /// Returns a copy with an additional registered [AgentRole].
  BuildContext withRole(AgentRole role) => BuildContext(
        pipelineSpec: pipelineSpec,
        roles: {...roles, role.roleId: role},
        mounts: mounts,
        environments: environments,
        properties: properties,
        typedValues: typedValues,
      );

  bool hasRole(String roleId) => roles.containsKey(roleId);
  bool hasMount(String prefix) => mounts.containsKey(prefix);
  bool hasEnvironment(String envId) => environments.containsKey(envId);
}
