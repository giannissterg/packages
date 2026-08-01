import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

// Custom reusable ComposableNode for testing
class SecurityAuditComponent extends ComposableNode {
  final String sourceFilePath;
  final String auditorRoleId;

  const SecurityAuditComponent({
    required this.sourceFilePath,
    required this.auditorRoleId,
  });

  @override
  WorkflowAstNode build(BuildContext context) {
    return StepTransactionNode(
      bodyNodes: [
        ReadDocumentNode(path: sourceFilePath, outputVariable: 'source_content'),
        PerformTaskNode(
          agentRoleId: auditorRoleId,
          task: TaskDefinition(
            taskId: 'security_audit',
            promptText: 'Audit $sourceFilePath for security vulnerabilities.',
            outputVariable: 'audit_report',
          ),
        ),
        OutputNode(outputVariable: 'audit_report'),
      ],
    );
  }
}

void main() {
  group('vaster_ast Nodes & ComposableNode', () {
    final spec = PipelineSpec(name: 'test_pipeline');
    final context = BuildContext(pipelineSpec: spec);

    test('PipelineNode holds body nodes', () {
      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'demo'),
        bodyNodes: [
          MountStorageNode(mount: StorageMount(mountPrefix: '/mem')),
          PromptModelNode(promptText: 'Hello', outputVariable: 'r0'),
          OutputNode(outputVariable: 'r0'),
        ],
      );
      expect(pipeline.bodyNodes, hasLength(3));
      expect(pipeline.bodyNodes.first, isA<MountStorageNode>());
      expect(pipeline.bodyNodes.last, isA<OutputNode>());
    });

    test('BuildContext carries pipeline spec and withRole creates new context', () {
      const role = AgentRole(
        roleId: 'eng',
        name: 'Engineer',
        title: 'Backend Dev',
        instruction: 'Write Dart code.',
      );
      final ctx2 = context.withRole(role);
      expect(ctx2.hasRole('eng'), isTrue);
      expect(context.hasRole('eng'), isFalse); // original unchanged
    });

    test('ComposableNode.build() expands into correct sub-tree', () {
      const component = SecurityAuditComponent(
        sourceFilePath: '/workspace/auth.dart',
        auditorRoleId: 'security_auditor',
      );

      final expanded = component.build(context);
      expect(expanded, isA<StepTransactionNode>());

      final tx = expanded as StepTransactionNode;
      expect(tx.bodyNodes, hasLength(3));
      expect(tx.bodyNodes.first, isA<ReadDocumentNode>());
      expect(tx.bodyNodes[1], isA<PerformTaskNode>());
      expect(tx.bodyNodes.last, isA<OutputNode>());
    });

    test('WhenConditionNode has then and else branches', () {
      const cond = WhenConditionNode(
        conditionVariable: 'should_review',
        thenNodes: [PromptModelNode(promptText: 'Do review')],
        elseNodes: [PromptModelNode(promptText: 'Skip review')],
      );
      expect(cond.thenNodes, hasLength(1));
      expect(cond.elseNodes, hasLength(1));
    });

    test('StepTransactionNode wraps body correctly', () {
      const tx = StepTransactionNode(
        bodyNodes: [
          WriteDocumentNode(path: '/mem/spec.md', content: '# Spec'),
          PerformTaskNode(
            agentRoleId: 'architect',
            task: TaskDefinition(taskId: 't1', promptText: 'Review spec'),
          ),
        ],
      );
      expect(tx.bodyNodes, hasLength(2));
    });
  });
}
