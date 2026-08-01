import 'package:vaster_domain/vaster_domain.dart';

/// Context passed during AST expansion and compilation.
///
/// Carries pipeline-level configuration and environment properties so that
/// [ComposableNode.build] implementations can react to the surrounding pipeline.
class BuildContext {
  /// The top-level pipeline specification.
  final PipelineSpec pipelineSpec;

  /// Currently registered agent roles (roleId -> AgentRole).
  final Map<String, AgentRole> roles;

  /// Currently registered storage mounts (mountPrefix -> StorageMount).
  final Map<String, StorageMount> mounts;

  /// Currently registered code environments (envId -> CodeEnvironment).
  final Map<String, CodeEnvironment> environments;

  /// Resolved register variables available at compile time.
  final Map<String, dynamic> properties;

  const BuildContext({
    required this.pipelineSpec,
    this.roles = const {},
    this.mounts = const {},
    this.environments = const {},
    this.properties = const {},
  });

  /// Returns a copy with additional properties merged in.
  BuildContext withProperty(String key, dynamic value) {
    return BuildContext(
      pipelineSpec: pipelineSpec,
      roles: roles,
      mounts: mounts,
      environments: environments,
      properties: {...properties, key: value},
    );
  }

  /// Returns a copy with an additional registered [AgentRole].
  BuildContext withRole(AgentRole role) {
    return BuildContext(
      pipelineSpec: pipelineSpec,
      roles: {...roles, role.roleId: role},
      mounts: mounts,
      environments: environments,
      properties: properties,
    );
  }

  bool hasRole(String roleId) => roles.containsKey(roleId);
  bool hasMount(String prefix) => mounts.containsKey(prefix);
  bool hasEnvironment(String envId) => environments.containsKey(envId);
}
