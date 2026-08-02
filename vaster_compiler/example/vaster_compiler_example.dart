import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';

// Custom ComposableNode — reusable code review component
class CodeReviewComponent extends ComposableNode {
  final String filePath;
  final String reviewerRoleId;

  const CodeReviewComponent({required this.filePath, required this.reviewerRoleId});

  @override
  VasterNode build(BuildContext context) {
    return Transaction(
      children: [
        ReadFile(path: filePath),
        Task(
          agentRoleId: reviewerRoleId,
          taskPrompt: 'Review the code at $filePath for quality and security issues.',
        ),
        const Output(),
      ],
    );
  }
}

void main() {
  print('================================================================');
  print('          Vaster Compiler Ecosystem Demo                       ');
  print('================================================================\n');

  const pipeline = Pipeline(
    spec: PipelineSpec(
      name: 'multi_agent_auth_pipeline',
      version: '1.0.0',
      rootStoragePath: '/workspace',
    ),
    children: [
      // Mount storage
      Mount(mount: StorageMount(mountPrefix: '/workspace')),

      // Define agent roles
      Agent(
        role: AgentRole(
          roleId: 'architect',
          name: 'Lead Architect',
          title: 'System Designer',
          instruction: 'You design scalable, production-ready system architectures.',
        ),
      ),
      Agent(
        role: AgentRole(
          roleId: 'developer',
          name: 'Backend Developer',
          title: 'Dart Engineer',
          instruction: 'You write clean, idiomatic Dart backend services.',
        ),
      ),

      // Write spec document
      WriteFile(
        path: '/workspace/spec.md',
        content: '# Auth Service Spec\nImplement JWT-based authentication.',
      ),

      // Architect designs the system
      Task(
        agentRoleId: 'architect',
        taskPrompt: 'Design an Auth Service from /workspace/spec.md.',
      ),

      // Developer implements it inside a transaction
      Transaction(
        children: [
          Task(
            agentRoleId: 'developer',
            taskPrompt: 'Implement the Auth Service based on the design.',
          ),
          WriteFile(path: '/workspace/auth.dart', content: '// Auth implementation'),
        ],
      ),

      // Use custom ComposableNode — code review component
      CodeReviewComponent(filePath: '/workspace/auth.dart', reviewerRoleId: 'architect'),

      Output(),
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
