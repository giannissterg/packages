part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Vaster Declarative Functional AST Nodes
//
// All container and scope nodes (Pipeline, Agent, ToolSet, Mount, Sandbox,
// SelectModel) are ComposableNodes that wrap their child sub-trees in
// Provider<T> nodes. Dataflow is TYPED: value-producing nodes accept an
// optional `output: Binding`, consumers reference the same Binding as a
// Template part or Cond operand, and BindingScope namespaces the defaults
// composables mint via context.scopedBinding (the Theme.of pattern). The
// pipeline's declared result (`Pipeline(result:)`) is what hosts read after
// halt. Raw `${name}` register strings remain only in the primitives tier.
//
// NEST vs SEQUENCE — the tree's design rule. A node nests children only when
// it changes what they MEAN:
//   * who executes them            → Agent(child:)
//   * their environment            → SelectModel / ToolSet / BudgetScope /
//                                    Sandbox / Mount / Provider
//   * their failure semantics      → Transaction / TryCatch / Resilient
//   * whether they run at all      → When / Decide paths / Review branches /
//                                    loop bodies
// Peer steps that merely run one after another are SIBLINGS — in
// Pipeline.children or an explicit Sequence. Data dependency alone never
// forces nesting: bindings and ${...} interpolation cross sibling
// boundaries freely.
// ══════════════════════════════════════════════════════════════════════════════

/// Top-level pipeline container.
///
/// Declared [roles], [mounts], [tools], and [model] are provisioned for real:
/// each emits its setup instruction before [children] run. [inputs] binds
/// named values available to `${name}` interpolation and conditions.
class Pipeline extends ComposableNode {
  /// Pipeline name — shorthand for `spec: PipelineSpec(name: ...)`.
  final String? name;

  /// Full pipeline specification; provide exactly one of [name]/[spec].
  final PipelineSpec? spec;

  final List<AgentRole> roles;
  final List<StorageMount> mounts;
  final List<ToolDefinition> tools;
  final ModelDescriptor? model;
  final Map<Binding, Object?> inputs;

  /// The program's declared result: hosts read this binding's register after
  /// halt. Compiled into the program header — replaces the legacy `Output`
  /// node and its `__output__` register convention.
  final Binding? result;
  final List<VasterNode> children;

  const Pipeline({
    this.name,
    this.spec,
    this.roles = const [],
    this.mounts = const [],
    this.tools = const [],
    this.model,
    this.inputs = const {},
    this.result,
    this.children = const [],
  }) : assert((name == null) != (spec == null), 'Provide exactly one of name/spec');

  /// The effective specification ([spec], or one built from [name]).
  PipelineSpec get effectiveSpec => spec ?? PipelineSpec(name: name!);

  @override
  VasterNode build(BuildContext context) {
    VasterNode tree = PipelineBody([
      if (inputs.isNotEmpty) InputsHeader(values: {for (final e in inputs.entries) e.key.name: e.value}),
      if (model != null) SelectModelHeader(model: model!),
      if (tools.isNotEmpty) ToolSetHeader(tools: tools),
      for (final mount in mounts) MountHeader(mount: mount),
      // Provisioning, not scoping: roles become live agents, but Task-level
      // role inheritance stays with the Agent scope node (multiple roles
      // cannot meaningfully share one Provider<AgentRole> slot).
      for (final role in roles) AgentProvisionHeader(role: role),
      ...children,
    ]);
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
    if (inputs.isNotEmpty) {
      tree = Provider<PipelineInputs>(
        value: PipelineInputs({for (final e in inputs.entries) e.key.name: e.value}),
        children: [tree],
      );
    }
    return Provider<PipelineSpec>(value: effectiveSpec, children: [tree]);
  }
}

/// Neutral grouping node: lowers to exactly its [children], no instructions
/// of its own. The building block for composables that expand to multiple
/// steps without imposing transaction or scope semantics.
final class Sequence extends VasterNode {
  final List<VasterNode> children;
  const Sequence(this.children);
}

/// Named input values for a subtree: available at build time via
/// `context.read<PipelineInputs>()` and bound as runtime values consumable
/// by `${name}` interpolation and `When`/`While` conditions.
///
/// This is how a pipeline receives arguments declaratively — the
/// `Provider`-flavored answer to seeding values, per the framework's
/// functional surface (no imperative variable mutation).
class Inputs extends ComposableNode {
  final Map<Binding, Object?> values;

  /// The subtree these inputs are visible to; omit to only bind them.
  final VasterNode? child;

  const Inputs(this.values, {this.child});

  @override
  VasterNode build(BuildContext context) {
    final named = {for (final e in values.entries) e.key.name: e.value};
    return Provider<PipelineInputs>(
      value: PipelineInputs(named),
      children: [
        InputsHeader(values: named),
        ?child,
      ],
    );
  }
}

/// Typed carrier for [Inputs]/[Pipeline.inputs] values in [BuildContext].
final class PipelineInputs {
  final Map<String, Object?> values;
  const PipelineInputs(this.values);

  Object? operator [](String name) => values[name];
}

/// Provisions an agent and scopes a single wrapped subtree to it — a true
/// provider node: descendants of [child] inherit this role (e.g. a [Task]
/// with no agent reference dispatches here).
///
/// For multiple steps under one agent, wrap them deliberately:
/// `Agent(role: architect, child: Sequence([...]))`.
class Agent extends ComposableNode {
  final AgentRole role;
  final VasterNode? child;

  const Agent({required this.role, this.child});

  @override
  VasterNode build(BuildContext context) {
    return Provider<AgentRole>(
      value: role,
      children: [
        AgentProvisionHeader(role: role),
        ?child,
      ],
    );
  }
}

/// ToolSet scope provider node.
class ToolSet extends ComposableNode {
  final List<ToolDefinition> tools;

  /// The subtree scoped to these tools; omit to only provision them.
  final VasterNode? child;

  const ToolSet({required this.tools, this.child});

  @override
  VasterNode build(BuildContext context) {
    return Provider<ToolSetData>(
      value: ToolSetData(tools),
      children: [
        ToolSetHeader(tools: tools),
        ?child,
      ],
    );
  }
}

/// Storage Mount scope provider node.
class Mount extends ComposableNode {
  final StorageMount mount;

  /// The subtree scoped to this mount; omit to only provision it.
  final VasterNode? child;

  const Mount({required this.mount, this.child});

  @override
  VasterNode build(BuildContext context) {
    return Provider<StorageMount>(
      value: mount,
      children: [
        MountHeader(mount: mount),
        ?child,
      ],
    );
  }
}

/// Budget scope provider node in AST.
/// Declares sub-tree budget constraints (maxTokens, maxCost, maxDuration).
class BudgetScope extends ComposableNode {
  final int? maxTokens;
  final double? maxCost;
  final Duration? maxDuration;

  /// The subtree bounded by this budget; omit to only declare it.
  final VasterNode? child;

  const BudgetScope({this.maxTokens, this.maxCost, this.maxDuration, this.child});

  @override
  VasterNode build(BuildContext context) {
    return Provider<BudgetConstraint>(
      value: BudgetConstraint(maxTokens: maxTokens, maxCost: maxCost, maxDuration: maxDuration),
      children: [
        BudgetHeader(maxTokens: maxTokens, maxCost: maxCost, maxDuration: maxDuration),
        ?child,
      ],
    );
  }
}

/// Data class carrying budget constraint parameters in BuildContext.
final class BudgetConstraint {
  final int? maxTokens;
  final double? maxCost;
  final Duration? maxDuration;

  const BudgetConstraint({this.maxTokens, this.maxCost, this.maxDuration});
}

/// Dispatches a task to an agent.
///
/// Reference the agent by [agent] object, by [agentId] string, or omit both
/// to inherit the enclosing [Agent] scope. [output] binds the result for
/// `${output}` interpolation downstream.
///
/// **Transactional by default** (REL-P4): the task wraps in a [Transaction],
/// so a failed task's VFS writes roll back — a retry starts from clean
/// state instead of half-written files. Transactions nest, so a `Task`
/// inside an explicit [Transaction] (or another `Task`) composes. Opt out
/// with `transactional: false` when partial writes are intentionally
/// durable.
class Task extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;
  final Template prompt;
  final Binding? output;

  /// Optional JSON Schema typing this task's output — the workflow-language
  /// equivalent of a return-type annotation. Lowered into the emitted
  /// [DispatchAgentTaskOp] so structured-output backends can enforce it.
  final Map<String, dynamic>? outputSchema;

  /// Whether this task's VFS effects roll back when it fails.
  final bool transactional;

  const Task({
    this.agent,
    this.agentId,
    required this.prompt,
    this.output,
    this.outputSchema,
    this.transactional = true,
  }) : assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final id = agent?.roleId ?? agentId ?? context.tryRead<AgentRole>()?.roleId ?? 'default';
    final execution = TaskExecution(
      agentId: id,
      prompt: prompt.lower(),
      output: output?.name,
      outputSchema: outputSchema,
    );
    return transactional ? Transaction(children: [execution]) : execution;
  }
}

/// Concurrently dispatches tasks across multiple agents.
final class ParallelTasks extends VasterNode {
  final List<ParallelTaskEntry> entries;

  const ParallelTasks({required this.entries});
}

/// Sends a direct prompt turn to the model.
final class Prompt extends VasterNode {
  final Template prompt;

  /// Binding for the response; auto-allocated when omitted.
  final Binding? output;

  /// Optional JSON Schema typing the prompt's output (return-type annotation).
  final Map<String, dynamic>? outputSchema;

  const Prompt(this.prompt, {this.output, this.outputSchema});
}

/// Writes content to a VFS path. Both [path] and [content] support
/// `${name}` interpolation.
final class WriteFile extends VasterNode {
  final Template path;
  final Template content;

  const WriteFile({required this.path, required this.content});
}

/// Reads a VFS path into [output] (auto-allocated when omitted). [path]
/// supports `${name}` interpolation.
final class ReadFile extends VasterNode {
  final Template path;
  final Binding? output;

  const ReadFile({required this.path, this.output});
}

/// Code Sandbox scope provider node.
class Sandbox extends ComposableNode {
  final CodeEnvironment env;

  /// The subtree scoped to this sandbox; omit to only register it.
  final VasterNode? child;

  const Sandbox({required this.env, this.child});

  @override
  VasterNode build(BuildContext context) {
    return Provider<CodeEnvironment>(
      value: env,
      children: [
        SandboxHeader(env: env),
        ?child,
      ],
    );
  }
}

/// Executes code in a registered sandbox environment. Omit [envId] to
/// inherit the enclosing [Sandbox] scope.
class Execute extends ComposableNode {
  final String? envId;
  final Template code;
  final Binding? output;

  const Execute({this.envId, required this.code, this.output});

  @override
  VasterNode build(BuildContext context) {
    final id = envId ?? context.tryRead<CodeEnvironment>()?.envId ?? 'default';
    return ExecuteExecution(envId: id, code: code.lower(), output: output?.name);
  }
}

/// Conditional branch: [then] runs when [condition] holds, else
/// [otherwise].
final class When extends VasterNode {
  final Cond condition;
  final List<VasterNode> then;
  final List<VasterNode> otherwise;

  const When({required this.condition, required this.then, this.otherwise = const []});
}

/// Transactional step boundary — automatically rolls back VFS state on failure.
final class Transaction extends VasterNode {
  final List<VasterNode> children;

  const Transaction({required this.children});
}

/// Model selection scope provider node.
///
/// [fallbacks] declares an ordered fallback chain (REL-P3): every model call
/// under this scope tries [model] first; a model-kind failure falls through
/// to each fallback in turn, each tried once. Cancellation never advances
/// the chain, and a policy violation is uncatchable everywhere. Retrying the
/// same model is [Resilient]'s job — `Resilient(child: SelectModel(...))`
/// retries the whole chain per attempt. The chain compiles into the
/// `SelectModelOp` as descriptor data: auditable (`vaster audit` lists it)
/// and priced (`vaster check` rates against the most expensive member).
class SelectModel extends ComposableNode {
  final ModelDescriptor model;

  /// Ordered fallback descriptors tried after [model], first to last.
  final List<ModelDescriptor> fallbacks;

  /// The subtree scoped to this model; omit to only switch the active model.
  final VasterNode? child;

  const SelectModel({required this.model, this.fallbacks = const [], this.child});

  @override
  VasterNode build(BuildContext context) {
    return Provider<ModelDescriptor>(
      value: model,
      children: [
        SelectModelHeader(model: model, fallbacks: fallbacks),
        ?child,
      ],
    );
  }
}

/// Sends an asynchronous actor message to a recipient agent.
///
/// Address the recipient by [to] object or [toId] string. The sender defaults
/// to the enclosing [Agent] scope; override with [from]/[fromId]. Payload
/// string values support `${name}` interpolation.
class SendMessage extends ComposableNode {
  final AgentRole? to;
  final String? toId;
  final AgentRole? from;
  final String? fromId;
  final Map<String, dynamic> payload;

  const SendMessage({this.to, this.toId, this.from, this.fromId, required this.payload})
    : assert((to == null) != (toId == null), 'Provide exactly one of to/toId'),
      assert(from == null || fromId == null, 'Provide at most one of from/fromId');

  @override
  VasterNode build(BuildContext context) {
    final senderId = from?.roleId ?? fromId ?? context.tryRead<AgentRole>()?.roleId ?? 'anonymous';
    return SendMessageExecution(fromId: senderId, toId: to?.roleId ?? toId!, payload: payload);
  }
}

/// Receives / pops the next unread actor message for an agent from their
/// inbox into [output]. The agent defaults to the enclosing [Agent] scope.
class ReceiveMessage extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;
  final Binding? output;

  const ReceiveMessage({this.agent, this.agentId, this.output})
    : assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final id = agent?.roleId ?? agentId ?? context.tryRead<AgentRole>()?.roleId ?? 'anonymous';
    return ReceiveMessageExecution(agentId: id, output: output?.name);
  }
}

/// One labeled path of a [Decide] or a [DecideLoop] exit — the model selects
/// it by [label], guided by [description].
class DecisionPath {
  final String label;
  final String description;
  final List<VasterNode> children;

  const DecisionPath({required this.label, required this.description, this.children = const []});
}

/// Declarative decision/iteration policy, injected Flutter-Theme-style via
/// `Provider<DecisionPolicy>`. Node-level fields override the provided
/// policy, which overrides library defaults.
class DecisionPolicy {
  /// Safety bound for [DecideLoop] iterations.
  final int maxIterations;

  /// Fallback path label taken when the model's answer resolves to no branch.
  final String? defaultPath;

  const DecisionPolicy({this.maxIterations = 8, this.defaultPath});
}

/// Model-steered branch: a pattern-match over model judgment.
///
/// The model is asked [prompt] and selects exactly one of [paths]; that
/// path's children execute, then control rejoins after the node. Every
/// destination is statically known — analyzers can enumerate the full
/// decision surface. The chosen label becomes the node's produced value,
/// bound to [output] when set.
final class Decide extends VasterNode {
  final Template prompt;
  final List<DecisionPath> paths;

  /// Path taken when the model's answer is unresolvable; overrides
  /// `DecisionPolicy.defaultPath` from context. With neither set, an
  /// unresolvable answer traps at runtime.
  final String? defaultPath;

  /// Binding name for the chosen label; the model's rationale lands in
  /// `<output>_rationale`. Auto-allocated when omitted.
  final Binding? output;

  const Decide({required this.prompt, required this.paths, this.defaultPath, this.output});
}

/// Declarative model-driven iteration: run [body], then the model decides
/// between continuing and the labeled [exits]. Iteration control *is* the
/// decision — no condition variables. The loop counter, guard, and back-edge
/// are compiler-internal, exactly like [While]/[Repeat] guards.
///
/// When [maxIterations] (node field, else `DecisionPolicy` from context,
/// else 8) is exhausted, the loop is forced out through [defaultPath] when it
/// names an exit, otherwise through the first exit.
final class DecideLoop extends VasterNode {
  final Template prompt;
  final List<VasterNode> body;
  final String continueLabel;
  final String continueDescription;
  final List<DecisionPath> exits;
  final String? defaultPath;
  final int? maxIterations;

  /// Nodes run on the continue edge — between the decision to keep going and
  /// the next pass of [body]. With an empty [body], this turns the loop
  /// decide-first: evaluate → exit, or run [onContinue] and re-evaluate
  /// (the review-then-revise shape).
  final List<VasterNode> onContinue;

  /// Binding for the final decision label; auto-allocated when omitted.
  final Binding? output;

  const DecideLoop({
    required this.prompt,
    required this.body,
    this.continueLabel = 'continue',
    this.continueDescription = 'another pass is needed',
    required this.exits,
    this.defaultPath,
    this.maxIterations,
    this.onContinue = const [],
    this.output,
  });
}

/// Yields execution to request human interaction.
///
/// Declarative fields only — the compiler materializes the ISA-level
/// interaction request when lowering. [interactionType] is the
/// `HumanInteractionType` name (`approval`, `question`, `input`, `review`).
/// The human's answer binds to [output]; whether it was affirmative
/// (approved/answered vs rejected/timed out) binds as a boolean to
/// `<output>_status`.
final class YieldHuman extends VasterNode {
  final String requestId;
  final String interactionType;
  final String prompt;
  final List<String> options;
  final String? output;
  final int? timeoutMs;

  const YieldHuman({
    required this.requestId,
    this.interactionType = 'question',
    required this.prompt,
    this.options = const [],
    this.output,
    this.timeoutMs,
  });
}

/// Asks a human user a question or presents a list of options. The answer
/// binds to [output] (auto-allocated when omitted).
final class AskHuman extends VasterNode {
  final String requestId;
  final Template prompt;
  final List<String> options;
  final Binding? output;

  const AskHuman({required this.requestId, required this.prompt, this.options = const [], this.output});
}

/// ComposableNode providing a Flutter-style human approval gate with
/// approve/reject branches.
class ApprovalGate extends ComposableNode {
  final String requestId;
  final Template prompt;
  final List<VasterNode> onApprove;
  final List<VasterNode> onReject;
  final int? timeoutMs;

  const ApprovalGate({
    required this.requestId,
    required this.prompt,
    required this.onApprove,
    this.onReject = const [],
    this.timeoutMs,
  });

  @override
  VasterNode build(BuildContext context) {
    return Transaction(
      children: [
        YieldHuman(
          requestId: requestId,
          interactionType: 'approval',
          prompt: prompt.lower(),
          options: const ['approve', 'reject'],
          output: requestId,
          timeoutMs: timeoutMs,
        ),
        When(
          condition: Cond.isTrue(Binding(hitlStatusRegister(requestId))),
          then: onApprove,
          otherwise: onReject,
        ),
      ],
    );
  }
}

/// Extracts JSON [field] from the value bound to [from] (default: the last
/// produced value) into a new binding [output]. The declarative way to
/// destructure a schema-typed result.
final class Extract extends VasterNode {
  final Binding? from;
  final String field;
  final Binding output;

  const Extract({this.from, required this.field, required this.output});
}

/// Injects a typed value [T] into [BuildContext] for all [children].
final class Provider<T> extends VasterNode {
  final T value;
  final List<VasterNode> children;

  const Provider({required this.value, required this.children});

  BuildContext applyToContext(BuildContext context) => context.provide<T>(value);
}
