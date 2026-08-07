part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Compiler lowering headers — emitted by ComposableNode.build() implementations
// above; not for direct authoring. Public so the compiler pattern-matches real
// types (the sealed VasterNode hierarchy makes its lowering switch exhaustive).
// ══════════════════════════════════════════════════════════════════════════════

/// Lowering header: the linear body of a [Pipeline].
final class PipelineBody extends VasterNode {
  final List<VasterNode> children;
  const PipelineBody(this.children);
}

/// Lowering header: provisions one agent (CreateAgent + CreateSession).
final class AgentProvisionHeader extends VasterNode {
  final AgentRole role;
  const AgentProvisionHeader({required this.role});
}

/// Lowering header: marks where provisioning for roles COLLECTED from the
/// subtree is spliced (AST_REVIEW F2). [Pipeline] emits it after its
/// explicit role headers; the compiler records the IR position and, after
/// lowering the whole tree (subroutines included), inserts CreateAgent +
/// CreateSession for every `agent:`-referenced role not already
/// provisioned — declaring `roles:` is for roles the tree cannot see
/// (`agentId:` string references).
final class CollectedRolesSlot extends VasterNode {
  const CollectedRolesSlot();
}

/// Lowering header: registers a tool set.
final class ToolSetHeader extends VasterNode {
  final List<ToolDefinition> tools;
  const ToolSetHeader({required this.tools});
}

/// Lowering header: mounts a VFS storage backend.
final class MountHeader extends VasterNode {
  final StorageMount mount;
  const MountHeader({required this.mount});
}

/// Lowering header: declares subtree budget constraints.
final class BudgetHeader extends VasterNode {
  final int? maxTokens;
  final double? maxCost;
  final Duration? maxDuration;

  const BudgetHeader({this.maxTokens, this.maxCost, this.maxDuration});
}

/// Lowering header: registers a code sandbox.
final class SandboxHeader extends VasterNode {
  final CodeEnvironment env;
  const SandboxHeader({required this.env});
}

/// Lowering header: selects the active model, with an optional ordered
/// fallback chain (REL-P3).
final class SelectModelHeader extends VasterNode {
  final ModelDescriptor model;
  final List<ModelDescriptor> fallbacks;
  const SelectModelHeader({required this.model, this.fallbacks = const []});
}

/// Lowering header: binds [Inputs]/[Pipeline.inputs] values at runtime.
final class InputsHeader extends VasterNode {
  final Map<String, Object?> values;
  const InputsHeader({required this.values});
}

/// Lowering header: a resolved [Task] dispatch.
final class TaskExecution extends VasterNode {
  final String agentId;
  final String prompt;
  final String? output;
  final Map<String, dynamic>? outputSchema;

  const TaskExecution({required this.agentId, required this.prompt, this.output, this.outputSchema});
}

/// Lowering header: a resolved [Execute] dispatch.
final class ExecuteExecution extends VasterNode {
  final String envId;
  final String code;
  final String? output;

  const ExecuteExecution({required this.envId, required this.code, this.output});
}

/// Lowering header: a resolved [SendMessage].
final class SendMessageExecution extends VasterNode {
  final String fromId;
  final String toId;
  final Map<String, dynamic> payload;

  const SendMessageExecution({required this.fromId, required this.toId, required this.payload});
}

/// Lowering header: a resolved [ReceiveMessage].
final class ReceiveMessageExecution extends VasterNode {
  final String agentId;
  final String? output;
  const ReceiveMessageExecution({required this.agentId, this.output});
}
