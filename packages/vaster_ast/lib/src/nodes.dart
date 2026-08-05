part of '../vaster_ast.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Vaster Declarative Functional AST Nodes
//
// All container and scope nodes (Pipeline, Agent, ToolSet, Mount, Sandbox,
// SelectModel) are ComposableNodes that wrap their child sub-trees in
// Provider<T> nodes. Value-producing nodes accept an optional `output:`
// binding name; downstream nodes consume bound values with `${name}`
// interpolation in prompts/content or by name in `When`/`While` conditions.
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
  final Map<String, Object?> inputs;
  final List<VasterNode> children;

  const Pipeline({
    this.name,
    this.spec,
    this.roles = const [],
    this.mounts = const [],
    this.tools = const [],
    this.model,
    this.inputs = const {},
    this.children = const [],
  }) : assert((name == null) != (spec == null),
            'Provide exactly one of name/spec');

  /// The effective specification ([spec], or one built from [name]).
  PipelineSpec get effectiveSpec => spec ?? PipelineSpec(name: name!);

  @override
  VasterNode build(BuildContext context) {
    VasterNode tree = PipelineBody([
      if (inputs.isNotEmpty) InputsHeader(values: inputs),
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
          value: PipelineInputs(inputs), children: [tree]);
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
  final Map<String, Object?> values;
  final List<VasterNode> children;

  const Inputs(this.values, {this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<PipelineInputs>(
      value: PipelineInputs(values),
      children: [
        InputsHeader(values: values),
        ...children,
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
  final List<VasterNode> children;

  const ToolSet({required this.tools, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<ToolSetData>(
      value: ToolSetData(tools),
      children: [
        ToolSetHeader(tools: tools),
        ...children,
      ],
    );
  }
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
        MountHeader(mount: mount),
        ...children,
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
        BudgetHeader(
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

/// Dispatches a task to an agent.
///
/// Reference the agent by [agent] object, by [agentId] string, or omit both
/// to inherit the enclosing [Agent] scope. [output] binds the result for
/// `${output}` interpolation downstream.
class Task extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;
  final String prompt;
  final String? output;

  /// Optional JSON Schema typing this task's output — the workflow-language
  /// equivalent of a return-type annotation. Lowered into the emitted
  /// [DispatchAgentTaskOp] so structured-output backends can enforce it.
  final Map<String, dynamic>? outputSchema;

  const Task({
    this.agent,
    this.agentId,
    required this.prompt,
    this.output,
    this.outputSchema,
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final id = agent?.roleId ??
        agentId ??
        context.tryRead<AgentRole>()?.roleId ??
        'default';
    return TaskExecution(
      agentId: id,
      prompt: prompt,
      output: output,
      outputSchema: outputSchema,
    );
  }
}

/// Concurrently dispatches tasks across multiple agents.
final class ParallelTasks extends VasterNode {
  final List<ParallelTaskEntry> entries;

  const ParallelTasks({required this.entries});
}

/// Sends a direct prompt turn to the model.
final class Prompt extends VasterNode {
  final String prompt;

  /// Binding name for the response; auto-allocated when omitted.
  final String? output;

  /// Optional JSON Schema typing the prompt's output (return-type annotation).
  final Map<String, dynamic>? outputSchema;

  const Prompt(this.prompt, {this.output, this.outputSchema});
}

/// Writes content to a VFS path. Both [path] and [content] support
/// `${name}` interpolation.
final class WriteFile extends VasterNode {
  final String path;
  final String content;

  const WriteFile({required this.path, required this.content});
}

/// Reads a VFS path into [output] (auto-allocated when omitted). [path]
/// supports `${name}` interpolation.
final class ReadFile extends VasterNode {
  final String path;
  final String? output;

  const ReadFile({required this.path, this.output});
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
        SandboxHeader(env: env),
        ...children,
      ],
    );
  }
}

/// Executes code in a registered sandbox environment. Omit [envId] to
/// inherit the enclosing [Sandbox] scope.
class Execute extends ComposableNode {
  final String? envId;
  final String code;
  final String? output;

  const Execute({this.envId, required this.code, this.output});

  @override
  VasterNode build(BuildContext context) {
    final id = envId ?? context.tryRead<CodeEnvironment>()?.envId ?? 'default';
    return ExecuteExecution(envId: id, code: code, output: output);
  }
}

/// Conditional branch node on the truthiness of the value bound to
/// [condition].
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
        SelectModelHeader(model: model),
        ...children,
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

  const SendMessage({
    this.to,
    this.toId,
    this.from,
    this.fromId,
    required this.payload,
  })  : assert((to == null) != (toId == null),
            'Provide exactly one of to/toId'),
        assert(from == null || fromId == null,
            'Provide at most one of from/fromId');

  @override
  VasterNode build(BuildContext context) {
    final senderId = from?.roleId ??
        fromId ??
        context.tryRead<AgentRole>()?.roleId ??
        'anonymous';
    return SendMessageExecution(
      fromId: senderId,
      toId: to?.roleId ?? toId!,
      payload: payload,
    );
  }
}

/// Receives / pops the next unread actor message for an agent from their
/// inbox into [output]. The agent defaults to the enclosing [Agent] scope.
class ReceiveMessage extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;
  final String? output;

  const ReceiveMessage({this.agent, this.agentId, this.output})
      : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final id = agent?.roleId ??
        agentId ??
        context.tryRead<AgentRole>()?.roleId ??
        'anonymous';
    return ReceiveMessageExecution(agentId: id, output: output);
  }
}

/// One labeled path of a [Decide] or a [DecideLoop] exit — the model selects
/// it by [label], guided by [description].
class DecisionPath {
  final String label;
  final String description;
  final List<VasterNode> children;

  const DecisionPath({
    required this.label,
    required this.description,
    this.children = const [],
  });
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
  final String prompt;
  final List<DecisionPath> paths;

  /// Path taken when the model's answer is unresolvable; overrides
  /// `DecisionPolicy.defaultPath` from context. With neither set, an
  /// unresolvable answer traps at runtime.
  final String? defaultPath;

  /// Binding name for the chosen label; the model's rationale lands in
  /// `<output>_rationale`. Auto-allocated when omitted.
  final String? output;

  const Decide({
    required this.prompt,
    required this.paths,
    this.defaultPath,
    this.output,
  });
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
  final String prompt;
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

  /// Binding name for the final decision label; auto-allocated when omitted.
  final String? output;

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
  final String prompt;
  final List<String> options;
  final String? output;

  const AskHuman({
    required this.requestId,
    required this.prompt,
    this.options = const [],
    this.output,
  });
}

/// ComposableNode providing a Flutter-style human approval gate with
/// approve/reject branches.
class ApprovalGate extends ComposableNode {
  final String requestId;
  final String prompt;
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
    return Transaction(children: [
      YieldHuman(
        requestId: requestId,
        interactionType: 'approval',
        prompt: prompt,
        options: const ['approve', 'reject'],
        output: requestId,
        timeoutMs: timeoutMs,
      ),
      When(
        condition: '${requestId}_status',
        then: onApprove,
        otherwise: onReject,
      ),
    ]);
  }
}

/// Declarative pipeline output node: copies the value bound to [from]
/// (default: the last produced value) into the program output.
final class Output extends VasterNode {
  final VasterNode? child;
  final String? from;

  const Output({this.child, this.from});
}

/// Extracts JSON [field] from the value bound to [from] (default: the last
/// produced value) into a new binding [output]. The declarative way to
/// destructure a schema-typed result.
final class Extract extends VasterNode {
  final String? from;
  final String field;
  final String output;

  const Extract({this.from, required this.field, required this.output});
}

/// Injects a typed value [T] into [BuildContext] for all [children].
final class Provider<T> extends VasterNode {
  final T value;
  final List<VasterNode> children;

  const Provider({required this.value, required this.children});

  BuildContext applyToContext(BuildContext context) => context.provide<T>(value);
}

// ══════════════════════════════════════════════════════════════════════════════
// Context — what the model knows.
//
// The declarative surface is [Knowledge]: a scope node declaring information
// the model sees while its subtree runs. Lifetime is structural — the region
// mounts on scope entry and unmounts on scope exit, so WHERE you declare
// knowledge in the tree IS how long it lives (declare at the Pipeline root
// for run-long knowledge, inside a phase for phase-long).
//
// The nodes below (AddContext, EvictContext, CompressContext) are the
// LOW-LEVEL heap tier — the lowering targets of Knowledge and ContextBudget.
// Prefer the declarative scopes.
// ══════════════════════════════════════════════════════════════════════════════

/// Declares knowledge the model sees while [child] runs — the declarative
/// context scope.
///
/// Content is [text] (supports `${name}` interpolation) or the value bound
/// to [from]. The region mounts before [child] and unmounts after it; a
/// [pinned] region is cache-hint eligible for its whole scope and is still
/// removed at scope exit.
///
/// ```dart
/// Knowledge(
///   label: 'project brief',
///   text: 'Build a notes app with offline sync.',
///   pinned: true,
///   child: Sequence([...the work grounded in the brief...]),
/// )
/// ```
class Knowledge extends ComposableNode {
  final String label;
  final String text;
  final String? from;

  /// Context class this knowledge belongs to (defaults to `knowledge`).
  /// Policy fields left null inherit from the class.
  final String className;
  final ContextPriority? priority;
  final ContextCompressibility? compressibility;
  final bool pinned;
  final VasterNode child;

  /// Region id override; defaults to a slug derived from [label]. Set it when
  /// two Knowledge scopes share a label.
  final String? id;

  const Knowledge({
    required this.label,
    this.text = '',
    this.from,
    this.className = ContextClassTable.knowledgeClassName,
    this.priority,
    this.compressibility,
    this.pinned = false,
    required this.child,
    this.id,
  });

  String get _regionId =>
      id ?? 'knowledge_${label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

  @override
  VasterNode build(BuildContext context) {
    final regionId = _regionId;
    return Sequence([
      AddContext(
        regionId: regionId,
        label: label,
        text: text,
        from: from,
        className: className,
        priority: priority,
        compressibility: compressibility,
        pinned: pinned,
      ),
      child,
      // Structural lifetime: the scope's end unmounts the region (force
      // clears pinning — pinning protects against mid-scope eviction, not
      // against the scope itself ending).
      EvictContext(regionId: regionId, force: true),
    ]);
  }
}

/// Declares a token budget for the context heap while [child] runs: the heap
/// is compacted toward [maxTokens] on scope entry (summarizing/truncating
/// regions per their declared compressibility).
///
/// ```dart
/// ContextBudget(
///   maxTokens: 12000,
///   child: Sequence([...long-running work...]),
/// )
/// ```
class ContextBudget extends ComposableNode {
  final int maxTokens;
  final VasterNode child;

  const ContextBudget({required this.maxTokens, required this.child});

  @override
  VasterNode build(BuildContext context) {
    return Sequence([
      CompressContext(targetTokens: maxTokens),
      child,
    ]);
  }
}

/// Declares (or overrides) context classes for the whole program — the
/// segment table of the context linker. Compiles into **static program
/// header metadata**, not instructions: class resolution is lexically
/// scoped to the program, never dependent on execution order.
///
/// The declared classes are layered over the standard table
/// ([ContextClassTable.standard]), so pipelines only state their deltas.
///
/// ```dart
/// ContextClasses(
///   classes: [
///     ContextClass(
///       name: 'domain_docs',
///       band: 22,
///       share: BudgetShare(minFraction: 0.2),
///       cacheStable: true,
///     ),
///   ],
///   child: Sequence([...]),
/// )
/// ```
final class ContextClasses extends VasterNode {
  final List<ContextClass> classes;
  final VasterNode child;

  const ContextClasses({required this.classes, required this.child});
}

// ── Low-level context heap tier ───────────────────────────────────────────────

/// Adds a context region to the VM context heap. Content is [text] (which
/// supports `${name}` interpolation), or the value bound to [from] at
/// runtime when set.
final class AddContext extends VasterNode {
  final String regionId;
  final String label;
  final String text;
  final String? from;

  /// Context class the region belongs to; null resolves to the table's
  /// default class. Null policy fields inherit from the class.
  final String? className;
  final ContextPriority? priority;
  final ContextLifetime? lifetime;
  final ContextCompressibility? compressibility;
  final bool pinned;

  const AddContext({
    required this.regionId,
    required this.label,
    this.text = '',
    this.from,
    this.className,
    this.priority,
    this.lifetime,
    this.compressibility,
    this.pinned = false,
  });
}

/// Removes a context region from the VM context heap.
final class EvictContext extends VasterNode {
  final String regionId;
  final bool force;

  const EvictContext({required this.regionId, this.force = false});
}

/// Low-level: compresses context toward a token target — the lowering target
/// of [ContextBudget], which is the declarative surface. Null [regionId]
/// compacts the whole heap; null [targetTokens] derives from the active
/// model budget. The freed-token count binds to [output].
final class CompressContext extends VasterNode {
  final String? regionId;
  final int? targetTokens;
  final String? output;

  const CompressContext({this.regionId, this.targetTokens, this.output});
}

// ══════════════════════════════════════════════════════════════════════════════
// Control-flow nodes — loops, subroutines, and error handling.
// ══════════════════════════════════════════════════════════════════════════════

/// Repeats [children] while the value bound to [condition] is truthy.
///
/// The condition is evaluated before each iteration (a standard while loop).
/// [maxIterations] is a compiled-in runaway guard: when reached, the loop
/// exits normally rather than spinning forever.
final class While extends VasterNode {
  final String condition;
  final List<VasterNode> children;
  final int maxIterations;

  const While({
    required this.condition,
    required this.children,
    this.maxIterations = 100,
  });
}

/// Executes [children] exactly [times] times. When [counter] is set, the
/// zero-based iteration index is bound to that name inside the body.
final class Repeat extends VasterNode {
  final int times;
  final List<VasterNode> children;
  final String? counter;

  const Repeat({required this.times, required this.children, this.counter});
}

/// Executes [tryChildren]; if any instruction inside throws, the error text
/// binds to [error] and control transfers to [catchChildren] instead of
/// trapping the VM. Policy violations are NOT catchable.
final class TryCatch extends VasterNode {
  final List<VasterNode> tryChildren;
  final List<VasterNode> catchChildren;
  final String error;

  const TryCatch({
    required this.tryChildren,
    this.catchChildren = const [],
    this.error = '__error__',
  });
}

/// Defines a named subroutine. Bodies are emitted after the main program and
/// are only reachable via [CallSubroutine]. The value of the body's last
/// output-producing node becomes the subroutine's return value.
final class DefineSubroutine extends VasterNode {
  final String name;
  final List<VasterNode> children;

  const DefineSubroutine({required this.name, required this.children});
}

/// Calls a [DefineSubroutine] by name. [arguments] are bound by name before
/// the jump; the subroutine's return value binds to [output] (auto-allocated
/// when omitted).
final class CallSubroutine extends VasterNode {
  final String name;
  final Map<String, dynamic> arguments;
  final String? output;

  const CallSubroutine({
    required this.name,
    this.arguments = const {},
    this.output,
  });
}

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

/// Lowering header: selects the active model.
final class SelectModelHeader extends VasterNode {
  final ModelDescriptor model;
  const SelectModelHeader({required this.model});
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

  const TaskExecution({
    required this.agentId,
    required this.prompt,
    this.output,
    this.outputSchema,
  });
}

/// Lowering header: a resolved [Execute] dispatch.
final class ExecuteExecution extends VasterNode {
  final String envId;
  final String code;
  final String? output;

  const ExecuteExecution({
    required this.envId,
    required this.code,
    this.output,
  });
}

/// Lowering header: a resolved [SendMessage].
final class SendMessageExecution extends VasterNode {
  final String fromId;
  final String toId;
  final Map<String, dynamic> payload;

  const SendMessageExecution({
    required this.fromId,
    required this.toId,
    required this.payload,
  });
}

/// Lowering header: a resolved [ReceiveMessage].
final class ReceiveMessageExecution extends VasterNode {
  final String agentId;
  final String? output;
  const ReceiveMessageExecution({required this.agentId, this.output});
}
