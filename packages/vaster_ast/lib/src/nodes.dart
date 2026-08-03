part of '../vaster_ast.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Vaster Declarative Functional AST Nodes
//
// All container and scope nodes (Pipeline, Agent, ToolSet, Mount, Sandbox, SelectModel)
// are ComposableNodes that wrap their child sub-trees in Provider<T> nodes.
// ══════════════════════════════════════════════════════════════════════════════

/// Top-level pipeline container.
class Pipeline extends ComposableNode {
  final PipelineSpec spec;
  final List<AgentRole> roles;
  final List<StorageMount> mounts;
  final List<ToolDefinition> tools;
  final ModelDescriptor? model;
  final List<VasterNode> children;

  const Pipeline({
    required this.spec,
    this.roles = const [],
    this.mounts = const [],
    this.tools = const [],
    this.model,
    this.children = const [],
  });

  @override
  VasterNode build(BuildContext context) {
    VasterNode tree = _PipelineBody(children);
    if (model != null) {
      tree = Provider<ModelDescriptor>(value: model!, children: [tree]);
    }
    if (tools.isNotEmpty) {
      tree = Provider<ToolSetData>(value: ToolSetData(tools), children: [tree]);
    }
    if (mounts.isNotEmpty) {
      tree = Provider<List<StorageMount>>(value: mounts, children: [tree]);
    }
    if (roles.isNotEmpty) {
      tree = Provider<List<AgentRole>>(value: roles, children: [tree]);
    }
    return Provider<PipelineSpec>(value: spec, children: [tree]);
  }
}

final class _PipelineBody extends VasterNode {
  final List<VasterNode> children;
  const _PipelineBody(this.children);
}

/// Provisions an agent role scope provider.
class Agent extends ComposableNode {
  final AgentRole role;
  final List<VasterNode> children;

  const Agent({required this.role, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<AgentRole>(
      value: role,
      children: [
        _AgentProvisionHeader(role: role),
        ...children,
      ],
    );
  }
}

final class _AgentProvisionHeader extends VasterNode {
  final AgentRole role;
  const _AgentProvisionHeader({required this.role});
}

/// ToolSet scope provider node.
class ToolSet extends ComposableNode {
  final List<ToolDefinition> tools;
  final List<VasterNode> children;

  const ToolSet({required this.tools, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<ToolSetData>(
      value: ToolSetData(tools),
      children: [
        _ToolSetHeader(tools: tools),
        ...children,
      ],
    );
  }
}

final class _ToolSetHeader extends VasterNode {
  final List<ToolDefinition> tools;
  const _ToolSetHeader({required this.tools});
}

/// Storage Mount scope provider node.
class Mount extends ComposableNode {
  final StorageMount mount;
  final List<VasterNode> children;

  const Mount({required this.mount, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<StorageMount>(
      value: mount,
      children: [
        _MountHeader(mount: mount),
        ...children,
      ],
    );
  }
}

final class _MountHeader extends VasterNode {
  final StorageMount mount;
  const _MountHeader({required this.mount});
}

/// Budget scope provider node in AST.
/// Enforces sub-tree budget constraints (maxTokens, maxCost, maxDuration).
class BudgetScope extends ComposableNode {
  final int? maxTokens;
  final double? maxCost;
  final Duration? maxDuration;
  final List<VasterNode> children;

  const BudgetScope({
    this.maxTokens,
    this.maxCost,
    this.maxDuration,
    this.children = const [],
  });

  @override
  VasterNode build(BuildContext context) {
    return Provider<BudgetConstraint>(
      value: BudgetConstraint(
        maxTokens: maxTokens,
        maxCost: maxCost,
        maxDuration: maxDuration,
      ),
      children: [
        _BudgetHeader(
          maxTokens: maxTokens,
          maxCost: maxCost,
          maxDuration: maxDuration,
        ),
        ...children,
      ],
    );
  }
}

/// Data class carrying budget constraint parameters in BuildContext.
final class BudgetConstraint {
  final int? maxTokens;
  final double? maxCost;
  final Duration? maxDuration;

  const BudgetConstraint({
    this.maxTokens,
    this.maxCost,
    this.maxDuration,
  });
}

final class _BudgetHeader extends VasterNode {
  final int? maxTokens;
  final double? maxCost;
  final Duration? maxDuration;

  const _BudgetHeader({
    this.maxTokens,
    this.maxCost,
    this.maxDuration,
  });
}

/// Dispatches a task to an agent role.
/// If [agentRoleId] is omitted, inherits from the enclosing [Agent] scope in [BuildContext].
class Task extends ComposableNode {
  final String? agentRoleId;
  final String taskPrompt;

  /// Optional JSON Schema typing this task's output — the workflow-language
  /// equivalent of a return-type annotation. Lowered into the emitted
  /// [DispatchAgentTaskOp] so structured-output backends can enforce it.
  final Map<String, dynamic>? outputSchema;

  const Task({this.agentRoleId, required this.taskPrompt, this.outputSchema});

  @override
  VasterNode build(BuildContext context) {
    final roleId = agentRoleId ?? context.tryRead<AgentRole>()?.roleId ?? 'default';
    return _TaskExecution(
      agentRoleId: roleId,
      taskPrompt: taskPrompt,
      outputSchema: outputSchema,
    );
  }
}

final class _TaskExecution extends VasterNode {
  final String agentRoleId;
  final String taskPrompt;
  final Map<String, dynamic>? outputSchema;
  const _TaskExecution({
    required this.agentRoleId,
    required this.taskPrompt,
    this.outputSchema,
  });
}

/// Concurrently dispatches tasks across multiple agent roles.
final class ParallelTasks extends VasterNode {
  final List<ParallelTaskEntry> entries;

  const ParallelTasks({required this.entries});
}

/// Sends a direct prompt turn to the model.
final class Prompt extends VasterNode {
  final String promptText;

  /// Optional JSON Schema typing the prompt's output (return-type annotation).
  final Map<String, dynamic>? outputSchema;

  const Prompt(this.promptText, {this.outputSchema});
}

/// Writes document content to a VFS path.
final class WriteFile extends VasterNode {
  final String path;
  final String content;

  const WriteFile({required this.path, required this.content});
}

/// Reads a document from a VFS path.
final class ReadFile extends VasterNode {
  final String path;

  const ReadFile({required this.path});
}

/// Code Sandbox scope provider node.
class Sandbox extends ComposableNode {
  final CodeEnvironment env;
  final List<VasterNode> children;

  const Sandbox({required this.env, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<CodeEnvironment>(
      value: env,
      children: [
        _SandboxHeader(env: env),
        ...children,
      ],
    );
  }
}

final class _SandboxHeader extends VasterNode {
  final CodeEnvironment env;
  const _SandboxHeader({required this.env});
}

/// Executes code in a registered sandbox environment.
final class Execute extends VasterNode {
  final String envId;
  final String code;

  const Execute({
    required this.envId,
    required this.code,
  });
}

/// Conditional branch node.
final class When extends VasterNode {
  final String condition;
  final List<VasterNode> then;
  final List<VasterNode> otherwise;

  const When({
    required this.condition,
    required this.then,
    this.otherwise = const [],
  });
}

/// Transactional step boundary — automatically rolls back VFS state on failure.
final class Transaction extends VasterNode {
  final List<VasterNode> children;

  const Transaction({required this.children});
}

/// Model selection scope provider node.
class SelectModel extends ComposableNode {
  final ModelDescriptor model;
  final List<VasterNode> children;

  const SelectModel({required this.model, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<ModelDescriptor>(
      value: model,
      children: [
        _SelectModelHeader(model: model),
        ...children,
      ],
    );
  }
}

final class _SelectModelHeader extends VasterNode {
  final ModelDescriptor model;
  const _SelectModelHeader({required this.model});
}

/// Sends an asynchronous actor message to a target recipient agent.
/// If [senderAgentId] is omitted, inherits from the enclosing [Agent] scope in [BuildContext].
class SendMessage extends ComposableNode {
  final String? senderAgentId;
  final String recipientAgentId;
  final Map<String, dynamic> payload;

  const SendMessage({
    this.senderAgentId,
    required this.recipientAgentId,
    required this.payload,
  });

  @override
  VasterNode build(BuildContext context) {
    final senderId = senderAgentId ?? context.tryRead<AgentRole>()?.roleId ?? 'anonymous';
    return _SendMessageExecution(
      senderAgentId: senderId,
      recipientAgentId: recipientAgentId,
      payload: payload,
    );
  }
}

final class _SendMessageExecution extends VasterNode {
  final String senderAgentId;
  final String recipientAgentId;
  final Map<String, dynamic> payload;

  const _SendMessageExecution({
    required this.senderAgentId,
    required this.recipientAgentId,
    required this.payload,
  });
}

/// Receives / pops the next unread actor message for an agent from their inbox.
/// If [agentId] is omitted, inherits from the enclosing [Agent] scope in [BuildContext].
class ReceiveMessage extends ComposableNode {
  final String? agentId;

  const ReceiveMessage({this.agentId});

  @override
  VasterNode build(BuildContext context) {
    final id = agentId ?? context.tryRead<AgentRole>()?.roleId ?? 'anonymous';
    return _ReceiveMessageExecution(agentId: id);
  }
}

final class _ReceiveMessageExecution extends VasterNode {
  final String agentId;
  const _ReceiveMessageExecution({required this.agentId});
}

/// Yields execution to request human interaction.
final class YieldHuman extends VasterNode {
  final HumanInteractionRequest request;

  const YieldHuman({required this.request});
}

/// Asks a human user a question or presents a list of options.
final class AskHuman extends VasterNode {
  final String requestId;
  final String prompt;
  final List<String> options;

  const AskHuman({
    required this.requestId,
    required this.prompt,
    this.options = const [],
  });
}

/// ComposableNode providing a Flutter-style human approval gate with
/// approve/reject branches.
class ApprovalGate extends ComposableNode {
  final String requestId;
  final String prompt;
  final List<VasterNode> onApprove;
  final List<VasterNode> onReject;

  const ApprovalGate({
    required this.requestId,
    required this.prompt,
    required this.onApprove,
    this.onReject = const [],
  });

  @override
  VasterNode build(BuildContext context) {
    return Transaction(children: [
      YieldHuman(
        request: HumanInteractionRequest(
          requestId: requestId,
          type: HumanInteractionType.approval,
          prompt: prompt,
          options: const ['approve', 'reject'],
          outputVar: requestId,
        ),
      ),
      When(
        condition: '${requestId}_status',
        then: onApprove,
        otherwise: onReject,
      ),
    ]);
  }
}

/// Declarative pipeline output node.
final class Output extends VasterNode {
  final VasterNode? child;
  final String? valueKey;

  const Output({this.child, this.valueKey});
}

/// Injects a typed value [T] into [BuildContext] for all [children].
final class Provider<T> extends VasterNode {
  final T value;
  final List<VasterNode> children;

  const Provider({required this.value, required this.children});

  BuildContext applyToContext(BuildContext context) => context.provide<T>(value);
}

// ══════════════════════════════════════════════════════════════════════════════
// Backwards Compatibility Node Aliases
// ══════════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════
// Context management nodes — declarative control over the VM context heap.
// ══════════════════════════════════════════════════════════════════════════════

/// Adds a context region to the VM context heap. Content is [text], or the
/// value of register [sourceVar] at runtime when set.
final class AddContext extends VasterNode {
  final String regionId;
  final String label;
  final String text;
  final String? sourceVar;
  final ContextPriority priority;
  final ContextLifetime lifetime;
  final ContextCompressibility compressibility;
  final bool pinned;

  const AddContext({
    required this.regionId,
    required this.label,
    this.text = '',
    this.sourceVar,
    this.priority = ContextPriority.medium,
    this.lifetime = ContextLifetime.session,
    this.compressibility = ContextCompressibility.none,
    this.pinned = false,
  });
}

/// Removes a context region from the VM context heap.
final class EvictContext extends VasterNode {
  final String regionId;
  final bool force;

  const EvictContext({required this.regionId, this.force = false});
}

/// Pins a context region (never evicted; eligible for provider-side caching
/// and physical KV materialization).
final class PinContext extends VasterNode {
  final String regionId;

  const PinContext({required this.regionId});
}

/// Unpins a context region.
final class UnpinContext extends VasterNode {
  final String regionId;

  const UnpinContext({required this.regionId});
}

/// Updates a region's management policy in place (only provided fields apply).
final class ContextPolicy extends VasterNode {
  final String regionId;
  final ContextPriority? priority;
  final bool? pinned;
  final ContextCompressibility? compressibility;
  final double? utility;

  const ContextPolicy({
    required this.regionId,
    this.priority,
    this.pinned,
    this.compressibility,
    this.utility,
  });
}

/// Compresses context toward a token target. Null [regionId] compacts the
/// whole heap; null [targetTokens] derives from the active model budget.
final class CompressContext extends VasterNode {
  final String? regionId;
  final int? targetTokens;

  const CompressContext({this.regionId, this.targetTokens});
}

typedef PipelineNode = Pipeline;
typedef MountStorageNode = Mount;
typedef DefineRoleNode = Agent;
typedef PerformTaskNode = Task;
typedef PerformParallelTasksNode = ParallelTasks;
typedef PromptModelNode = Prompt;
typedef WriteDocumentNode = WriteFile;
typedef ReadDocumentNode = ReadFile;
typedef RegisterCodeEnvironmentNode = Sandbox;
typedef ExecuteCodeNode = Execute;
typedef WhenConditionNode = When;
typedef StepTransactionNode = Transaction;
typedef SelectModelNode = SelectModel;
typedef YieldHumanInteractionNode = YieldHuman;
typedef AskHumanQuestionNode = AskHuman;
typedef HumanApprovalComponent = ApprovalGate;
typedef OutputNode = Output;
typedef ProviderNode<T> = Provider<T>;