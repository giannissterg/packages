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
        ReadFile(path: Template.text(filePath)),
        // Task automatically reads enclosing AgentRole from context!
        const Task(
            prompt:
                Template.text('Review the code for quality and security issues.'),
            output: Binding('code_review')),
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
    result: const Binding('code_review'),
    spec: const PipelineSpec(
      name: 'multi_agent_auth_pipeline',
      version: '1.0.0',
      rootStoragePath: '/workspace',
    ),
    mounts: const [StorageMount(mountPrefix: '/workspace')],
    children: [
      // Write spec document
      const WriteFile(
        path: Template.text('/workspace/spec.md'),
        content: Template.text('# Auth Service Spec\nImplement JWT-based authentication.'),
      ),

      // Architect Agent Scope
      Agent(
        role: architectRole,
        child: const Task(prompt: Template.text('Design an Auth Service from /workspace/spec.md.')),
      ),

      // Developer Agent Scope
      Agent(
        role: developerRole,
        child: Transaction(
          children: [
            const Task(prompt: Template.text('Implement the Auth Service based on the design.')),
            const WriteFile(path: Template.text('/workspace/auth.dart'), content: Template.text('// Auth implementation')),
          ],
        ),
      ),

      // Architect Code Review Scope
      Agent(
        role: architectRole,
        child: const CodeReviewComponent(filePath: '/workspace/auth.dart'),
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  print('Pipeline: ${pipeline.effectiveSpec.name} v${pipeline.effectiveSpec.version}');
  print('Compiled ${program.instructions.length} ISA instructions:\n');

  for (var i = 0; i < program.instructions.length; i++) {
    final inst = program.instructions[i];
    final json = inst.toJson();
    print('  [$i] ${json['opcode']}');
  }

  print('\nProgram JSON serializable: ${program.toJson().keys.toList()}');
  print('\nDone!');
}
