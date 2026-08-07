import 'dart:async';
import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';
import 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'program_execution_job.dart';

/// Concrete Master Virtual Machine Engine implementation orchestrating all Vaster sub-systems.
class VasterVMEngine implements VasterVirtualMachine {
  @override
  final VMConfig config;

  @override
  final SessionManager sessionManager;

  @override
  final ContextManager contextManager;

  @override
  final FileSystemManager fileSystemManager;

  @override
  final ToolManager toolManager;

  @override
  final SandboxManager sandboxManager;

  @override
  final AgentManager agentManager;

  @override
  final ToolEffectRecorderBinding agentToolRecorder;

  @override
  final ToolCallGateBinding agentToolGate;

  @override
  final RuntimeEventBus eventBus;

  @override
  final AgentMessagingHub messagingHub;

  @override
  final ResourceTracker resourceTracker;

  @override
  final ModelRegistry modelRegistry;

  @override
  final PolicyEngine policyEngine;

  @override
  final VasterScheduler scheduler;

  @override
  final ExecutionBudget rootBudget;

  /// The VM's metering pipeline: every model call the VM owns (prompt funnel,
  /// context compression, agent turns) resolves cost, emits one
  /// [ModelUsageEvent], and charges [resourceTracker] through this meter.
  final ModelCallMeter meter;

  final Map<String, ProgramExecutionJob> _jobs = {};

  @override
  ContextWorkspace get contextWorkspace => ContextWorkspace(contextManager);

  VasterVMEngine._({
    required this.config,
    required this.sessionManager,
    required this.contextManager,
    required this.fileSystemManager,
    required this.toolManager,
    required this.sandboxManager,
    required this.agentManager,
    required this.agentToolRecorder,
    required this.agentToolGate,
    required this.eventBus,
    required this.messagingHub,
    required this.resourceTracker,
    required this.modelRegistry,
    required this.policyEngine,
    required this.scheduler,
    required this.rootBudget,
    required this.meter,
  });

  /// Factory bootstrap method to create a fully configured [VasterVMEngine].
  static Future<VasterVMEngine> bootstrap({
    required VMConfig config,
    VasterFileSystem? rootFileSystem,
    List<ExecutableTool> initialTools = const [],
    List<CodeSandbox> initialSandboxes = const [],
    PolicyEngine? policyEngine,
    VasterScheduler? scheduler,
    ExecutionBudget? rootBudget,
  }) async {
    final eventBus = BasicEventBus();
    final messagingHub = BasicAgentMessagingHub();
    final resourceTracker = ResourceTracker(quota: config.defaultQuota);

    // The VM's single metering pipeline (cost + telemetry + tracker charge).
    final meter = ModelCallMeter(
      pricingCatalog: config.pricingCatalog,
      sinks: [TrackerSink(resourceTracker)],
      eventBus: eventBus,
    );
    // Agent turns charge tokens to the shared tracker inside the agent's own
    // loop (quota enforcement lives there) — this meter adds what that loop
    // cannot: cost resolution and per-turn telemetry.
    final agentTurnMeter = ModelCallMeter(
      pricingCatalog: config.pricingCatalog,
      sinks: [TrackerSink(resourceTracker, chargeTokens: false)],
      eventBus: eventBus,
    );

    final sessionManager = BasicSessionManager();
    final contextManager = BasicContextManager(
      eventBus: eventBus,
      compressors: [
        SummarizingCompressor(
          model: config.defaultModel,
          onUsage: (usage) => meter.charge(
            usage: usage,
            modelName: config.defaultModel.modelName,
            callSite: 'context_compression',
          ),
        ),
        const TruncatingCompressor(),
      ],
    );
    final fileSystemManager = BasicFileSystemManager();
    final toolManager = BasicToolManager(tools: initialTools);
    final sandboxManager = BasicSandboxManager(sandboxes: initialSandboxes);
    final activePolicyEngine = policyEngine ?? BasicPolicyEngine(eventBus: eventBus);
    final activeScheduler = scheduler ??
        BasicVasterScheduler(taskQueue: PriorityTaskQueue(), cores: config.cores);
    final activeRootBudget = rootBudget ?? ExecutionBudget.unlimited();

    // GAP-3a: agents hold this binding eagerly; the executing runtime
    // binds its effect ledger's adapter so agent tool calls replay across
    // retry attempts. Unbound = no-op passthrough.
    final agentToolRecorder = ToolEffectRecorderBinding();
    // A1: the program's policy gate reaches agent loops through this
    // binding; agents additionally compose their own descriptor policy.
    final agentToolGate = ToolCallGateBinding();
    final agentManager = AdvancedAgentManager(
      sessionManager: sessionManager,
      eventBus: eventBus,
      resourceTracker: resourceTracker,
      toolEffectRecorder: agentToolRecorder,
      // A1: every agent answers to the program's policy (bound by the
      // executing runtime); a descriptor-declared agent policy composes
      // ON TOP — the dormant AgentDescriptor.policy field becomes law.
      toolCallGateFor: (descriptor) => descriptor.policy != null
          ? CompositeToolCallGate([
              PolicyGuard(
                  engine: activePolicyEngine, policy: descriptor.policy!),
              agentToolGate,
            ])
          : agentToolGate,
      // Tool-loop turns were invisible to metering: only a task-level rollup
      // with wire-reported cost existed. Per-turn wiring meters every model
      // call an agent makes as it happens.
      onTurnUsage: (usage, modelName) => agentTurnMeter.charge(
        usage: usage,
        modelName: modelName,
        callSite: 'agent_turn',
      ),
    );

    final modelRegistry = ModelRegistry(defaultModel: config.defaultModel);

    final vm = VasterVMEngine._(
      config: config,
      sessionManager: sessionManager,
      contextManager: contextManager,
      fileSystemManager: fileSystemManager,
      toolManager: toolManager,
      sandboxManager: sandboxManager,
      agentManager: agentManager,
      agentToolRecorder: agentToolRecorder,
      agentToolGate: agentToolGate,
      eventBus: eventBus,
      messagingHub: messagingHub,
      resourceTracker: resourceTracker,
      modelRegistry: modelRegistry,
      policyEngine: activePolicyEngine,
      scheduler: activeScheduler,
      rootBudget: activeRootBudget,
      meter: meter,
    );

    // Automatic Bridge 1: Mount root filesystem if provided, or default MemoryVasterFileSystem
    final rootFs = rootFileSystem ?? MemoryVasterFileSystem();
    vm.mountFileSystem(config.rootMountPath, rootFs);

    // Automatic Bridge 2: Register initial sandboxes into ToolManager
    for (final sb in initialSandboxes) {
      vm.registerSandbox(sb);
    }

    // Automatic Bridge 3: Register VFS syscalls as first-class tools so their
    // schemas are advertised to models and available to agents. NOTE: the
    // runtime's tool-calling loop executes these two names through its own
    // policy-gated built-in path (which takes precedence); these registrations
    // serve definition advertisement and agent/tool-manager callers.
    vm.registerTool(FunctionTool.define(
      name: VfsSyscalls.writeFileName,
      description: 'Write text content to a file in the virtual filesystem.',
      parametersSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute VFS path'},
          'content': {'type': 'string', 'description': 'Text content to write'},
        },
        'required': ['path', 'content'],
      },
      handler: (args) => VfsSyscalls.writeFile(vm.fileSystemManager, args),
    ));
    vm.registerTool(FunctionTool.define(
      name: VfsSyscalls.readFileName,
      description: 'Read text content from a file in the virtual filesystem.',
      parametersSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute VFS path'},
        },
        'required': ['path'],
      },
      handler: (args) => VfsSyscalls.readFile(vm.fileSystemManager, args),
    ));

    return vm;
  }

  /// Host-facing: submits an ISA program for multi-pipeline time-sliced
  /// execution. Deliberately NOT part of [VasterVirtualMachine] — the
  /// runtime never schedules jobs; only hosts do.
  ProgramExecutionJob submitProgram(
    VasterProgram program, {
    required ExecutionPolicy policy,
    required ExecutionBudget budget,
    TaskPriority priority = TaskPriority.normal,
  }) {
    final jobId = 'job_${_jobs.length + 1}_${program.programName}';

    final runtime = VasterRuntime(
      vm: this,
      policy: policy,
      budget: budget,
      scheduler: scheduler,
    );

    final job = ProgramExecutionJob(
      jobId: jobId,
      program: program,
      runtime: runtime,
      budget: budget,
      priority: priority,
      lastState: const RuntimeState(pc: 0, status: RuntimeStatus.idle),
    );

    _jobs[jobId] = job;
    _enqueueQuantum(job);
    return job;
  }

  /// Enqueues the next scheduling quantum of [job] as a [ScheduledTask].
  ///
  /// A quantum is the dispatchable unit of program execution: its action
  /// advances the job's runtime by [_stepQuantum] instructions, and the
  /// scheduler's [VasterScheduler.runNext] owns its full lifecycle — budget
  /// pre-check, `running` → `completed`/`failed`/`timedOut` transitions, and
  /// completer resolution. A job still running after its quantum re-enqueues
  /// the next one, competing again on priority/deadline order.
  void _enqueueQuantum(ProgramExecutionJob job) {
    final task = ScheduledTask<RuntimeState>(
      taskId: job.jobId,
      taskName: job.program.programName,
      priority: job.priority,
      budget: job.budget,
      action: () => _runJobQuantum(job),
    );
    // Quantum outcomes are read off job.lastState rather than awaited per
    // task, so a budget-expiry completeError from runNext must not surface as
    // an unhandled async error.
    task.completer.future.ignore();
    scheduler.taskQueue.enqueue(task);
  }

  Future<RuntimeState> _runJobQuantum(ProgramExecutionJob job) async {
    final state =
        await job.runtime.executeStep(job.program, stepCount: _stepQuantum);
    job.lastState = state;
    _quantumResults?[job.jobId] = state;
    if (!job.isDone && !job.isPausedForHuman) _enqueueQuantum(job);
    return state;
  }

  /// Instruction quantum applied to job tasks dispatched via the scheduler.
  int _stepQuantum = 5;

  /// Per-run sink recording each job's latest state while [runScheduledJobs]
  /// drains the queue; null outside a run.
  Map<String, RuntimeState>? _quantumResults;

  /// Host-facing companion to [submitProgram].
  Future<Map<String, RuntimeState>> runScheduledJobs({int stepQuantum = 5}) async {
    _stepQuantum = stepQuantum;
    final results = _quantumResults = <String, RuntimeState>{};
    try {
      // The scheduler owns the drain: its worker pool dispatches up to
      // `cores` quanta concurrently, so one job's model I/O overlaps another
      // job's execution while priority order still governs dispatch.
      await scheduler.runAll();
    } finally {
      _quantumResults = null;
    }

    // A quantum the scheduler refused to dispatch (budget already expired at
    // pre-check) never runs its action, leaving the job stranded mid-flight.
    // Land it as timedOut — the same verdict executeStep reaches when it
    // performs the budget check itself.
    for (final job in _jobs.values) {
      if (!job.isDone && !job.isPausedForHuman && job.budget.isExpired) {
        job.lastState = job.lastState.copyWith(
          status: RuntimeStatus.timedOut,
          errorDetails:
              'Execution budget or deadline expired before quantum dispatch',
        );
        results[job.jobId] = job.lastState;
      }
    }

    return results;
  }

  @override
  Future<ModelSession> createSession({
    required String sessionId,
    ModelDescriptor? modelDescriptor,
  }) async {
    // Get-or-create: ISA programs may provision the same session twice (e.g.
    // CreateAgentOp followed by CreateSessionOp for the same role). The strict
    // duplicate guard lives in BasicSessionManager.createSession.
    final existing = sessionManager.getSession(sessionId);
    if (existing != null) return existing;

    final model = (modelDescriptor != null
        ? modelRegistry.resolveModel(modelDescriptor)
        : config.defaultModel);
    if (model == null) {
      throw StateError('No model registered for session "$sessionId".');
    }

    final session = await sessionManager.createSession(
      sessionId: sessionId,
      model: model,
      // Layered like agents (see _layeredContextManager): a plain session
      // must also see ambient pinned regions.
      contextManager: _layeredContextManager(model),
    );

    eventBus.publish(SessionCreatedEvent(
      eventId: 'evt_session_created_$sessionId',
      sessionId: sessionId,
      modelName: model.modelName,
    ));

    return session;
  }

  @override
  Future<ModelResponse> prompt(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  }) async {
    cancelToken?.throwIfCancelled();
    resourceTracker.checkDeadline();
    final activeModel = model ?? this.config.defaultModel;

    final compiled = await _compileGlobalContext(activeModel);
    final request = ModelRequest(
      systemInstruction: compiled.systemInstruction,
      messages: [...compiled.messages, ChatMessage.user(promptText)],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints ?? const [],
    );

    final response = await activeModel.generate(request);
    _meterCall(
      response.usage.totalTokenCount > 0
          ? response.usage
          : TokenEstimate.forExchange(
              prompt: promptText, output: response.text),
      activeModel,
      servedBy: response.servedBy,
    );

    // Turn boundary — same discipline as the session path: ephemeral
    // scratch regions expire once the turn that used them completes.
    contextManager.pruneLifetimes({ContextLifetime.ephemeral});
    return response;
  }

  @override
  Future<ModelResponse> promptWithHistory(
    List<ChatMessage> messages, {
    VasterModel? model,
    List<ToolDefinition>? tools,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  }) async {
    cancelToken?.throwIfCancelled();
    resourceTracker.checkDeadline();
    final activeModel = model ?? this.config.defaultModel;

    final compiled = await _compileGlobalContext(activeModel);
    final request = ModelRequest(
      systemInstruction: compiled.systemInstruction,
      messages: [...compiled.messages, ...messages],
      tools: tools ?? const [],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints ?? const [],
    );

    final response = await activeModel.generate(request);
    _meterCall(
      response.usage.totalTokenCount > 0
          ? response.usage
          // The fallback must count the sent history too, not just the reply.
          : UsageMetadata(
              promptTokenCount: TokenEstimate.forMessages(messages),
              candidatesTokenCount: TokenEstimate.forText(response.text),
            ),
      activeModel,
      servedBy: response.servedBy,
    );

    // Turn boundary — same discipline as the session path.
    contextManager.pruneLifetimes({ContextLifetime.ephemeral});
    return response;
  }

  @override
  Future<ModelResponse> promptInSession(
    String sessionId,
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  }) async {
    cancelToken?.throwIfCancelled();
    resourceTracker.checkDeadline();

    var session = sessionManager.getSession(sessionId);
    session ??= await createSession(sessionId: sessionId);

    final response = await session.send(
      ChatMessage.user(promptText),
      targetModel: model,
      config: config,
      cancelToken: cancelToken,
      // Forward cache hints — this path silently dropped them before, so
      // pinned-region cache breakpoints never reached session-backed prompts.
      cacheHints: cacheHints ?? const [],
    );

    _meterCall(
      response.usage.totalTokenCount > 0
          ? response.usage
          : TokenEstimate.forExchange(
              prompt: promptText, output: response.text),
      model ?? this.config.defaultModel,
      servedBy: response.servedBy,
    );

    return response;
  }

  /// Compiles the VM's global context regions into the leading segment
  /// of a sessionless request — same budget shape as the session path.
  ///
  /// Sessionless prompts previously sent ONLY the turn text: pinned
  /// `Knowledge` never reached the model on ANY backend, which the KV
  /// prefix validation caught live (a knowledge-state restore was
  /// rejected against a knowledge-less prompt). With no regions
  /// installed the compile is empty and requests are unchanged.
  Future<CompiledContext> _compileGlobalContext(VasterModel activeModel) =>
      contextManager.compileContext(
        budget: TokenBudget(
          maxContextTokens: activeModel.capabilities.maxContextTokens,
          reservedOutputTokens: activeModel.capabilities.maxOutputTokens,
          reservedToolTokens: 0,
        ),
      );

  /// Meters one model call at the VM funnel through [meter]: one
  /// [ModelUsageEvent] published before charging (usage stays observable even
  /// when a quota trips), tokens charged, and cost charged when known.
  ///
  /// [servedBy] is the response's serving-model stamp — set when a fallback
  /// chain member served the call, so attribution (and the catalog rate)
  /// follows the model that really ran, not the chain's head.
  void _meterCall(UsageMetadata usage, VasterModel model,
          {String? servedBy}) =>
      meter.charge(
        usage: usage,
        modelName: servedBy ?? model.modelName,
        callSite: 'vm_prompt',
      );

  /// Layered context for anything that owns a conversation: a private
  /// manager (history source + session-local regions) over the shared
  /// VM-wide manager, so ambient pinned regions (Knowledge) remain
  /// visible while per-session history stays isolated. One owner for the
  /// pattern — plain sessions and agents MUST compile the same layering,
  /// or pinned context silently vanishes from one of them (found live:
  /// plain sessions were built with a bare private manager and never saw
  /// global Knowledge).
  CompositeContextManager _layeredContextManager(VasterModel model) =>
      CompositeContextManager(
        children: [
          BasicContextManager(
            eventBus: eventBus,
            compressors: [
              _meteredCompressor(model),
              const TruncatingCompressor(),
            ],
          ),
          contextManager,
        ],
        compressors: [
          _meteredCompressor(model),
          const TruncatingCompressor(),
        ],
      );

  /// A summarizing compressor whose token burn is on the books: compaction
  /// calls meter through the VM pipeline like any other model call.
  SummarizingCompressor _meteredCompressor(VasterModel model) =>
      SummarizingCompressor(
        model: model,
        onUsage: (usage) => meter.charge(
          usage: usage,
          modelName: model.modelName,
          callSite: 'context_compression',
        ),
      );

  @override
  Stream<ModelResponseChunk> promptStream(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  }) async* {
    cancelToken?.throwIfCancelled();
    resourceTracker.checkDeadline();
    final activeModel = model ?? this.config.defaultModel;

    final compiled = await _compileGlobalContext(activeModel);
    final request = ModelRequest(
      systemInstruction: compiled.systemInstruction,
      messages: [...compiled.messages, ChatMessage.user(promptText)],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints ?? const [],
    );

    // Streaming is metered like any other call: chunk usage is a cumulative
    // snapshot (take-last, never sum). If the stream dies before a usage
    // snapshot arrives, a labeled estimate from the accumulated text stands
    // in so streamed work is never free.
    UsageMetadata? streamUsage;
    final textBuffer = StringBuffer();
    try {
      await for (final chunk in activeModel.generateStream(request)) {
        if (chunk.textDelta != null) textBuffer.write(chunk.textDelta);
        if (chunk.usage != null) streamUsage = chunk.usage;
        yield chunk;
      }
    } finally {
      _meterCall(
        streamUsage ??
            TokenEstimate.forExchange(
                prompt: promptText, output: textBuffer.toString()),
        activeModel,
      );
      // Turn boundary — same discipline as the session path.
      contextManager.pruneLifetimes({ContextLifetime.ephemeral});
    }
  }

  @override
  String mountFileSystem(String pathPrefix, VasterFileSystem fs) {
    final normalized = fileSystemManager.mount(pathPrefix, fs);

    // Bridge: Publish file operation event — under the NORMALIZED prefix,
    // the identity resolution actually uses.
    eventBus.publish(FileOperationEvent(
      eventId: 'evt_mount_$normalized',
      operation: FileOperationType.mount,
      path: normalized,
      sizeBytes: 0,
    ));
    return normalized;
  }

  @override
  Map<String, VasterModel> registerModel(
          ModelDescriptor descriptor, VasterModel model) =>
      modelRegistry.registerModel(descriptor, model);

  @override
  ExecutableTool? registerTool(ExecutableTool tool) =>
      toolManager.registerTool(tool);

  @override
  ({CodeSandbox? sandbox, ExecutableTool? bridgedTool}) registerSandbox(
      CodeSandbox sandbox) {
    final displacedSandbox = sandboxManager.registerSandbox(sandbox);

    // Bridge: Automatically create executable tool for sandbox and register in ToolManager
    final sandboxTool = sandboxManager.createSandboxTool(
      sandboxId: sandbox.descriptor.sandboxId,
      toolName: 'exec_${sandbox.descriptor.sandboxId}',
      description: sandbox.descriptor.description,
    );
    // Both registrations displace; reporting one hid the other.
    final displacedTool = toolManager.registerTool(sandboxTool);
    return (sandbox: displacedSandbox, bridgedTool: displacedTool);
  }

  @override
  CodeSandbox mountSandbox(String sandboxId, SandboxLanguage language,
      {Duration? timeout}) {
    final sandbox = IsolateCodeSandbox(
      descriptor: SandboxDescriptor(
        sandboxId: sandboxId,
        type: 'isolate',
        description: 'ISA Isolate Sandbox',
        supportedLanguages: [language],
      ),
      defaultPolicy: SandboxSecurityPolicy(
        maxTimeout: timeout ?? const Duration(seconds: 10),
      ),
    );
    registerSandbox(sandbox);
    return sandbox;
  }

  @override
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    VasterModel? model,
    String? parentAgentId,
  }) async {
    // Precedence: explicit host override → descriptor chain → VM default.
    // A declared chain (GAP-3b) resolves through the registry and composes
    // the same one-attempt ResilientVasterModel as the runtime's active
    // model: each member tried once, model-kind failures advance
    // (publishing ModelFallbackEvent), cancellation never does, and the
    // serving member stamps servedBy for attribution.
    final activeModel =
        model ?? _resolveDescriptorChain(descriptor) ?? config.defaultModel;

    return await agentManager.createAgent(
      descriptor: descriptor,
      model: activeModel,
      // Layered context (see _layeredContextManager): private history over
      // the shared VM-wide manager — ambient regions remain visible.
      contextManager: _layeredContextManager(activeModel),
      toolManager: toolManager,
    );
  }

  /// Resolves an agent descriptor's declared model (+ fallback chain) via
  /// the ONE shared composer, or null when the descriptor declares none.
  VasterModel? _resolveDescriptorChain(AgentDescriptor descriptor) =>
      ModelChainResolver(registry: modelRegistry, eventBus: eventBus).resolve(
        primary: descriptor.modelDescriptor,
        fallbacks: descriptor.modelFallbacks,
        eventScope: 'agent_${descriptor.agentId}',
      );

  @override
  Future<AgentOutput> runAgentTask(
    AgentTask task, {
    String? agentId,
  }) async {
    resourceTracker.checkDeadline();

    String targetAgentId = agentId ?? VasterVirtualMachine.defaultRootAgentId;
    var targetAgent = agentManager.getAgent(targetAgentId);

    targetAgent ??= await createAgent(
      descriptor: AgentDescriptor(
        agentId: targetAgentId,
        name: 'VasterRootAgent',
        role: 'Primary Agent',
        systemInstruction: 'You are the primary autonomous agent of VasterVM.',
      ),
    );

    return await agentManager.dispatchTask(
      agentId: targetAgentId,
      task: task,
    );
  }

  @override
  Future<({int sessionsClosed, bool messagingClosed, bool eventBusClosed})>
      shutdown() async {
    final sessionsClosed = await sessionManager.closeAllSessions();
    final messagingClosed = await messagingHub.close();
    final eventBusClosed = await eventBus.close();
    return (
      sessionsClosed: sessionsClosed,
      messagingClosed: messagingClosed,
      eventBusClosed: eventBusClosed,
    );
  }
}
