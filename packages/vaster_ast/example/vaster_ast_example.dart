import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

// Typed Configuration Model
class ProjectConfig {
  final String projectName;
  final String environment;
  const ProjectConfig({required this.projectName, required this.environment});
}

// Custom ComposableNode Component
class SecurityAuditComponent extends ComposableNode {
  const SecurityAuditComponent();

  @override
  VasterNode build(BuildContext context) {
    final cfg = context.get<ProjectConfig>();
    return Transaction(
      children: [
        Prompt('Audit ${cfg.projectName} (${cfg.environment}) for security compliance.'),
      ],
    );
  }
}

void main() {
  print('================================================================');
  print('          Vaster Declarative Functional AST Demo               ');
  print('================================================================\n');

  const architectRole = AgentRole(
    roleId: 'architect',
    name: 'Lead Architect',
    title: 'Principal Software Architect',
    instruction: 'You design scalable system architectures.',
  );

  // Declarative Functional AST Tree
  final pipeline = Pipeline(
    name: 'declarative_ast_demo',
    mounts: const [StorageMount(mountPrefix: '/workspace')],
    roles: const [architectRole],
    children: [
      const WriteFile(path: '/workspace/brief.md', content: 'Build a cloud REST API.'),

      // `output:` binds a step's value; later steps consume it with ${...}.
      const ReadFile(path: '/workspace/brief.md', output: 'brief'),

      // Inject typed configuration into context tree using Provider<T>
      Provider<ProjectConfig>(
        value: const ProjectConfig(projectName: 'NexusCloud', environment: 'production'),
        children: [
          // Agent Scope Provider wrapping its child sub-tree
          Agent(
            role: architectRole,
            child: const Sequence([
              // Declarative Functional Component
              SecurityAuditComponent(),

              // Task inherits architectRole from BuildContext, and its prompt
              // interpolates the bound brief at runtime.
              Task(
                prompt: 'Produce the final system architecture document for '
                    'this brief:\n\${brief}',
                output: 'architecture',
              ),
            ]),
          ),
        ],
      ),

      const Output(from: 'architecture'),
    ],
  );

  print('AST Tree Assembled Successfully!');
  print('Root Pipeline Spec: ${pipeline.effectiveSpec.name}');
  print('Root Mounts: ${pipeline.mounts.map((m) => m.mountPrefix).join(', ')}');
  print('Root Roles: ${pipeline.roles.map((r) => r.roleId).join(', ')}');
}
