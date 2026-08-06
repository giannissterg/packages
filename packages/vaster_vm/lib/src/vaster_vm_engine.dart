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

    final agentManager = AdvancedAgentManager(
      sessionManager: sessionManager,
      eventBus: eventBus,
      resourceTracker: resourceTracker,
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
      handler: (args) => VfsSyscalls.writeFile(vm, args),
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
      handler: (args) => VfsSyscalls.readFile(vm, args),
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
      contextManager: BasicContextManager(
        eventBus: eventBus,
        compressors: [
          _meteredCompressor(model),
          const TruncatingCompressor(),
        ],
      ),
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
    );

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
    );

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
  void _meterCall(UsageMetadata usage, VasterModel model) => meter.charge(
        usage: usage,
        modelName: model.modelName,
        callSite: 'vm_prompt',
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
    }
  }

  @override
  void mountFileSystem(String pathPrefix, VasterFileSystem fs) {
    fileSystemManager.mount(pathPrefix, fs);

    // Bridge: Publish file operation event
    eventBus.publish(FileOperationEvent(
      eventId: 'evt_mount_$pathPrefix',
      operation: FileOperationType.mount,
      path: pathPrefix,
      sizeBytes: 0,
    ));
  }

  @override
  void registerModel(ModelDescriptor descriptor, VasterModel model) {
    modelRegistry.registerModel(descriptor, model);
  }

  @override
  void registerTool(ExecutableTool tool) {
    toolManager.registerTool(tool);
  }

  @override
  void registerSandbox(CodeSandbox sandbox) {
    sandboxManager.registerSandbox(sandbox);

    // Bridge: Automatically create executable tool for sandbox and register in ToolManager
    final sandboxTool = sandboxManager.createSandboxTool(
      sandboxId: sandbox.descriptor.sandboxId,
      toolName: 'exec_${sandbox.descriptor.sandboxId}',
      description: sandbox.descriptor.description,
    );
    toolManager.registerTool(sandboxTool);
  }

  @override
  void mountSandbox(String sandboxId, SandboxLanguage language,
      {Duration? timeout}) {
    registerSandbox(IsolateCodeSandbox(
      descriptor: SandboxDescriptor(
        sandboxId: sandboxId,
        type: 'isolate',
        description: 'ISA Isolate Sandbox',
        supportedLanguages: [language],
      ),
      defaultPolicy: SandboxSecurityPolicy(
        maxTimeout: timeout ?? const Duration(seconds: 10),
      ),
    ));
  }

  @override
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    VasterModel? model,
    String? parentAgentId,
  }) async {
    final activeModel = model ?? config.defaultModel;

    return await agentManager.createAgent(
      descriptor: descriptor,
      model: activeModel,
      // Layered context: the agent session's private manager (children.first
      // — receives its history source and session-local regions) over the
      // shared VM-wide manager (ambient regions remain visible). This keeps
      // per-session history isolated instead of projecting every session's
      // turns into one shared heap.
      contextManager: CompositeContextManager(
        children: [
          BasicContextManager(
            eventBus: eventBus,
            compressors: [
              _meteredCompressor(activeModel),
              const TruncatingCompressor(),
            ],
          ),
          contextManager,
        ],
        compressors: [
          _meteredCompressor(activeModel),
          const TruncatingCompressor(),
        ],
      ),
      toolManager: toolManager,
    );
  }

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
  Future<void> shutdown() async {
    await sessionManager.closeAllSessions();
    await messagingHub.close();
    await eventBus.close();
  }
}
