import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';

// Custom ComposableNode — reusable code review component
class CodeReviewComponent extends ComposableNode {
  final String filePath;
  final String reviewerRoleId;

  const CodeReviewComponent({
    required this.filePath,
    required this.reviewerRoleId,
  });

  @override
  WorkflowAstNode build(BuildContext context) {
    return StepTransactionNode(bodyNodes: [
      ReadDocumentNode(path: filePath, outputVariable: 'source_code'),
      PerformTaskNode(
        agentRoleId: reviewerRoleId,
        task: TaskDefinition(
          taskId: 'review_code',
          promptText: 'Review the code at $filePath for quality and security issues.',
          outputVariable: 'review_report',
        ),
      ),
      OutputNode(outputVariable: 'review_report'),
    ]);
  }
}

void main() {
  print('================================================================');
  print('          Vaster Compiler Ecosystem Demo                       ');
  print('================================================================\n');

  const pipeline = PipelineNode(
    spec: PipelineSpec(
      name: 'multi_agent_auth_pipeline',
      version: '1.0.0',
      rootStoragePath: '/workspace',
    ),
    bodyNodes: [
      // Mount storage
      MountStorageNode(mount: StorageMount(mountPrefix: '/workspace')),

      // Define agent roles
      DefineRoleNode(
        role: AgentRole(
          roleId: 'architect',
          name: 'Lead Architect',
          title: 'System Designer',
          instruction: 'You design scalable, production-ready system architectures.',
        ),
      ),
      DefineRoleNode(
        role: AgentRole(
          roleId: 'developer',
          name: 'Backend Developer',
          title: 'Dart Engineer',
          instruction: 'You write clean, idiomatic Dart backend services.',
        ),
      ),

      // Write spec document
      WriteDocumentNode(
        path: '/workspace/spec.md',
        content: '# Auth Service Spec\nImplement JWT-based authentication.',
      ),

      // Architect designs the system
      PerformTaskNode(
        agentRoleId: 'architect',
        task: TaskDefinition(
          taskId: 'design_system',
          promptText: 'Design an Auth Service from /workspace/spec.md.',
          outputVariable: 'design',
        ),
      ),

      // Developer implements it inside a transaction
      StepTransactionNode(bodyNodes: [
        PerformTaskNode(
          agentRoleId: 'developer',
          task: TaskDefinition(
            taskId: 'implement_auth',
            promptText: 'Implement the Auth Service based on the design.',
            outputVariable: 'implementation',
          ),
        ),
        WriteDocumentNode(path: '/workspace/auth.dart', content: '// Auth implementation'),
      ]),

      // Use custom ComposableNode — code review component
      CodeReviewComponent(
        filePath: '/workspace/auth.dart',
        reviewerRoleId: 'architect',
      ),

      OutputNode(outputVariable: 'review_report'),
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
