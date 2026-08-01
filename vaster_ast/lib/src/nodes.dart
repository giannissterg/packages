part of '../vaster_ast.dart';

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

/// Reads a document from a VFS path into an output variable.
final class ReadDocumentNode extends WorkflowAstNode {
  final String path;
  final String? outputVariable;

  const ReadDocumentNode({required this.path, this.outputVariable});
}

/// Registers a code execution environment in the pipeline.
final class RegisterCodeEnvironmentNode extends WorkflowAstNode {
  final CodeEnvironment env;

  const RegisterCodeEnvironmentNode({required this.env});
}

/// Executes code in a registered code environment.
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

/// Selects the active LLM model descriptor for subsequent pipeline execution.
final class SelectModelNode extends WorkflowAstNode {
  final ModelDescriptor model;

  const SelectModelNode({required this.model});
}

/// AST node yielding execution to request human interaction.
final class YieldHumanInteractionNode extends WorkflowAstNode {
  final HumanInteractionRequest request;

  const YieldHumanInteractionNode({required this.request});
}

/// AST node asking a human user a question or presenting a list of options.
final class AskHumanQuestionNode extends WorkflowAstNode {
  final String requestId;
  final String prompt;
  final List<String> options;
  final String outputVariable;

  const AskHumanQuestionNode({
    required this.requestId,
    required this.prompt,
    this.options = const [],
    required this.outputVariable,
  });
}

/// ComposableNode providing a Flutter-style human approval gate with approve/reject branches.
class HumanApprovalComponent extends ComposableNode {
  final String requestId;
  final String prompt;
  final List<WorkflowAstNode> onApprove;
  final List<WorkflowAstNode> onReject;

  const HumanApprovalComponent({
    required this.requestId,
    required this.prompt,
    required this.onApprove,
    this.onReject = const [],
  });

  @override
  WorkflowAstNode build(BuildContext context) {
    return StepTransactionNode(bodyNodes: [
      YieldHumanInteractionNode(
        request: HumanInteractionRequest(
          requestId: requestId,
          type: HumanInteractionType.approval,
          prompt: prompt,
          options: const ['approve', 'reject'],
          outputVar: requestId,
        ),
      ),
      WhenConditionNode(
        conditionVariable: '${requestId}_status',
        thenNodes: onApprove,
        elseNodes: onReject,
      ),
    ]);
  }
}

/// Defines a reusable subroutine function in the workflow AST.
final class DefineFunctionNode extends WorkflowAstNode {
  final String functionName;
  final List<String> parameters;
  final List<WorkflowAstNode> bodyNodes;

  const DefineFunctionNode({
    required this.functionName,
    this.parameters = const [],
    required this.bodyNodes,
  });
}

/// Returns execution from a subroutine function, optionally returning [returnVariable].
final class ReturnNode extends WorkflowAstNode {
  final String? returnVariable;

  const ReturnNode({this.returnVariable});
}

/// Invokes a defined subroutine function by [functionName].
final class CallFunctionNode extends WorkflowAstNode {
  final String functionName;
  final Map<String, String> arguments;
  final String? outputVariable;

  const CallFunctionNode({
    required this.functionName,
    this.arguments = const {},
    this.outputVariable,
  });
}

/// Returns a pipeline output register variable as the final result.
final class OutputNode extends WorkflowAstNode {
  final String outputVariable;

  const OutputNode({required this.outputVariable});
}

/// Injects a typed value [T] into [BuildContext] for all [children].
///
/// Children (and their descendants) can access the value via
/// `context.read<T>()` or `context.tryRead<T>()`.
///
/// This is a **compile-time only** construct — it leaves no ISA footprint.
///
/// Example:
/// ```dart
/// ProviderNode<DatabaseConfig>(
///   value: DatabaseConfig(host: 'localhost', port: 5432),
///   children: [
///     DefineRoleNode(...),
///     PerformTaskNode(...), // ComposableNodes here can call context.read<DatabaseConfig>()
///   ],
/// )
/// ```
final class ProviderNode<T> extends WorkflowAstNode {
  final T value;
  final List<WorkflowAstNode> children;

  const ProviderNode({required this.value, required this.children});

  /// Injects [value] into [context] preserving the type parameter [T].
  ///
  /// Called by the compiler when encountering this node, before recursing
  /// into [children] with the enriched context.
  BuildContext applyToContext(BuildContext context) => context.provide<T>(value);
}
