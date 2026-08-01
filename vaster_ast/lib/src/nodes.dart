import 'package:vaster_domain/vaster_domain.dart';
import 'workflow_ast_node.dart';

/// Top-level pipeline container node.
final class PipelineNode extends WorkflowAstNode {
  final PipelineSpec spec;
  final List<WorkflowAstNode> bodyNodes;

  const PipelineNode({required this.spec, this.bodyNodes = const []});
}

/// Mounts virtual or disk-backed storage.
final class MountStorageNode extends WorkflowAstNode {
  final StorageMount mount;

  const MountStorageNode({required this.mount});
}

/// Provisions an agent role into the pipeline.
final class DefineRoleNode extends WorkflowAstNode {
  final AgentRole role;

  const DefineRoleNode({required this.role});
}

/// Asks a specific agent role to perform a task.
final class PerformTaskNode extends WorkflowAstNode {
  final String agentRoleId;
  final TaskDefinition task;

  const PerformTaskNode({required this.agentRoleId, required this.task});
}

/// Concurrently performs tasks across multiple agent roles.
final class PerformParallelTasksNode extends WorkflowAstNode {
  final List<ParallelTaskEntry> entries;

  const PerformParallelTasksNode({required this.entries});
}

/// Sends a direct prompt turn to the model.
final class PromptModelNode extends WorkflowAstNode {
  final String promptText;
  final String? outputVariable;

  const PromptModelNode({required this.promptText, this.outputVariable});
}

/// Writes document content to a VFS path.
final class WriteDocumentNode extends WorkflowAstNode {
  final String path;
  final String content;

  const WriteDocumentNode({required this.path, required this.content});
}

/// Reads a document from a VFS path into a variable.
final class ReadDocumentNode extends WorkflowAstNode {
  final String path;
  final String? outputVariable;

  const ReadDocumentNode({required this.path, this.outputVariable});
}

/// Registers and executes code in an environment.
final class ExecuteCodeNode extends WorkflowAstNode {
  final String envId;
  final String code;
  final String? outputVariable;

  const ExecuteCodeNode({
    required this.envId,
    required this.code,
    this.outputVariable,
  });
}

/// Conditional branch node.
///
/// Evaluates [conditionVariable] at runtime and executes [thenNodes] if truthy,
/// or [elseNodes] if falsy.
final class WhenConditionNode extends WorkflowAstNode {
  final String conditionVariable;
  final List<WorkflowAstNode> thenNodes;
  final List<WorkflowAstNode> elseNodes;

  const WhenConditionNode({
    required this.conditionVariable,
    required this.thenNodes,
    this.elseNodes = const [],
  });
}

/// Transactional step boundary — automatically rolls back VFS state on failure.
final class StepTransactionNode extends WorkflowAstNode {
  final List<WorkflowAstNode> bodyNodes;

  const StepTransactionNode({required this.bodyNodes});
}

/// Returns a pipeline output register variable as the final result.
final class OutputNode extends WorkflowAstNode {
  final String outputVariable;

  const OutputNode({required this.outputVariable});
}
