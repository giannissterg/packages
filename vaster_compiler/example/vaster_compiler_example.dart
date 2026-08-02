import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';

// Custom ComposableNode — reusable code review component
class CodeReviewComponent extends ComposableNode {
  final String filePath;

  const CodeReviewComponent({required this.filePath});

  @override
  VasterNode build(BuildContext context) {
    return Transaction(
      children: [
        ReadFile(path: filePath),
        // Task automatically reads enclosing AgentRole from context!
        const Task(taskPrompt: 'Review the code for quality and security issues.'),
        const Output(),
      ],
    );
  }
}

void main() {
  print('================================================================');
  print('          Vaster Compiler Ecosystem Demo                       ');
  print('================================================================\n');

  const architectRole = AgentRole(
    roleId: 'architect',
    name: 'Lead Architect',
    title: 'System Designer',
    instruction: 'You design scalable, production-ready system architectures.',
  );

  const developerRole = AgentRole(
    roleId: 'developer',
    name: 'Backend Developer',
    title: 'Dart Engineer',
    instruction: 'You write clean, idiomatic Dart backend services.',
  );

  // Declarative Functional AST Tree
  final pipeline = Pipeline(
    spec: const PipelineSpec(
      name: 'multi_agent_auth_pipeline',
      version: '1.0.0',
      rootStoragePath: '/workspace',
    ),
    mounts: const [StorageMount(mountPrefix: '/workspace')],
    children: [
      // Write spec document
      const WriteFile(
        path: '/workspace/spec.md',
        content: '# Auth Service Spec\nImplement JWT-based authentication.',
      ),

      // Architect Agent Scope
      Agent(
        role: architectRole,
        children: [
          const Task(taskPrompt: 'Design an Auth Service from /workspace/spec.md.'),
        ],
      ),

      // Developer Agent Scope
      Agent(
        role: developerRole,
        children: [
          Transaction(
            children: [
              const Task(taskPrompt: 'Implement the Auth Service based on the design.'),
              const WriteFile(path: '/workspace/auth.dart', content: '// Auth implementation'),
            ],
          ),
        ],
      ),

      // Architect Code Review Scope
      Agent(
        role: architectRole,
        children: [
          const CodeReviewComponent(filePath: '/workspace/auth.dart'),
        ],
      ),

      const Output(),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  print('Pipeline: ${pipeline.spec.name} v${pipeline.spec.version}');
  print('Compiled ${program.instructions.length} ISA instructions:\n');

  for (var i = 0; i < program.instructions.length; i++) {
    final inst = program.instructions[i];
    final json = inst.toJson();
    print('  [$i] ${json['opcode']}');
  }

  print('\nProgram JSON serializable: ${program.toJson().keys.toList()}');
  print('\nDone!');
}
