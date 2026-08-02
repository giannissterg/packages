part of '../vaster_ast.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Vaster AST Nodes
//
// All node types follow Flutter naming conventions: short, declarative names
// without the "Node" suffix. Container nodes use `children` for their body.
// ══════════════════════════════════════════════════════════════════════════════

/// Top-level pipeline container.
///
/// The root of every Vaster workflow. Holds the [PipelineSpec] metadata and
/// the list of [children] nodes that make up the pipeline body.
///
/// Example:
/// ```dart
/// Pipeline(
///   spec: PipelineSpec(name: 'my_pipeline'),
///   children: [
///     Mount(mount: StorageMount(mountPrefix: '/workspace')),
///     Prompt(promptText: 'Hello', output: 'r0'),
///     Output(output: 'r0'),
///   ],
/// )
/// ```
final class Pipeline extends VasterNode {
  final PipelineSpec spec;
  final List<VasterNode> children;

  const Pipeline({required this.spec, this.children = const []});
}

/// Mounts virtual or disk-backed storage into the pipeline's VFS.
final class Mount extends VasterNode {
  final StorageMount mount;

  const Mount({required this.mount});
}

/// Provisions an agent role into the pipeline.
///
/// Creates an agent with the given [role] and an associated session.
final class Agent extends VasterNode {
  final AgentRole role;

  const Agent({required this.role});
}

/// Dispatches a task to a specific agent role.
///
/// The agent identified by [agentRoleId] receives [task] and produces
/// output into the task's [outputVariable].
final class Task extends VasterNode {
  final String agentRoleId;
  final TaskDefinition task;

  const Task({required this.agentRoleId, required this.task});
}

/// Concurrently dispatches tasks across multiple agent roles.
///
/// All [entries] execute in parallel. Each [ParallelTaskEntry] targets
/// a specific agent role with its own prompt and output variable.
final class ParallelTasks extends VasterNode {
  final List<ParallelTaskEntry> entries;

  const ParallelTasks({required this.entries});
}

/// Sends a direct prompt turn to the model.
///
/// The [promptText] is sent as-is to the current model session.
/// If [output] is provided, the response is stored in that register.
final class Prompt extends VasterNode {
  final String promptText;
  final String? output;

  const Prompt({required this.promptText, this.output});
}

/// Writes document content to a VFS path.
final class WriteFile extends VasterNode {
  final String path;
  final String content;

  const WriteFile({required this.path, required this.content});
}

/// Reads a document from a VFS path into an output register.
final class ReadFile extends VasterNode {
  final String path;
  final String? output;

  const ReadFile({required this.path, this.output});
}

/// Registers a code execution sandbox environment in the pipeline.
final class Sandbox extends VasterNode {
  final CodeEnvironment env;

  const Sandbox({required this.env});
}

/// Executes code in a registered sandbox environment.
final class Execute extends VasterNode {
  final String envId;
  final String code;
  final String? output;

  const Execute({
    required this.envId,
    required this.code,
    this.output,
  });
}

/// Conditional branch node.
///
/// Evaluates [condition] at runtime and executes [then] children if truthy,
/// or [otherwise] children if falsy.
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
///
/// All [children] execute within a transaction. If any child fails,
/// the VFS state is rolled back to the point before the transaction began.
final class Transaction extends VasterNode {
  final List<VasterNode> children;

  const Transaction({required this.children});
}

/// Selects the active LLM model descriptor for subsequent pipeline execution.
final class SelectModel extends VasterNode {
  final ModelDescriptor model;

  const SelectModel({required this.model});
}

/// Yields execution to request human interaction.
final class YieldHuman extends VasterNode {
  final HumanInteractionRequest request;

  const YieldHuman({required this.request});
}

/// Asks a human user a question or presents a list of options.
///
/// The response is stored in [output] as a string matching one of [options].
final class AskHuman extends VasterNode {
  final String requestId;
  final String prompt;
  final List<String> options;
  final String output;

  const AskHuman({
    required this.requestId,
    required this.prompt,
    this.options = const [],
    required this.output,
  });
}

/// ComposableNode providing a Flutter-style human approval gate with
/// approve/reject branches.
///
/// Yields a human interaction request of type [HumanInteractionType.approval].
/// If approved, [onApprove] children execute. If rejected, [onReject] children
/// execute instead.
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

/// Defines a reusable subroutine function in the workflow.
///
/// Subroutines are compiled into jump-isolated program memory blocks.
/// They can be invoked via [Call] nodes and may return a value via [Return].
final class Subroutine extends VasterNode {
  final String name;
  final List<String> params;
  final List<VasterNode> children;

  const Subroutine({
    required this.name,
    this.params = const [],
    required this.children,
  });
}

/// Returns execution from a subroutine, optionally returning [value].
final class Return extends VasterNode {
  final String? value;

  const Return({this.value});
}

/// Invokes a defined subroutine function by [name].
///
/// Arguments are passed as a map of register names. If [output] is provided,
/// the subroutine's return value is stored in that register.
final class Call extends VasterNode {
  final String name;
  final Map<String, String> arguments;
  final String? output;

  const Call({
    required this.name,
    this.arguments = const {},
    this.output,
  });
}

/// Returns a pipeline output register variable as the final result.
final class Output extends VasterNode {
  final String output;

  const Output({required this.output});
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
/// Provider<DatabaseConfig>(
///   value: DatabaseConfig(host: 'localhost', port: 5432),
///   children: [
///     Agent(...),
///     Task(...), // ComposableNodes here can call context.read<DatabaseConfig>()
///   ],
/// )
/// ```
final class Provider<T> extends VasterNode {
  final T value;
  final List<VasterNode> children;

  const Provider({required this.value, required this.children});

  /// Injects [value] into [context] preserving the type parameter [T].
  ///
  /// Called by the compiler when encountering this node, before recursing
  /// into [children] with the enriched context.
  BuildContext applyToContext(BuildContext context) => context.provide<T>(value);
}