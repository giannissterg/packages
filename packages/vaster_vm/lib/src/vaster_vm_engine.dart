import 'dart:async';
import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'model_registry.dart';
import 'program_execution_job.dart';
import 'vaster_vm_interface.dart';
import 'vm_config.dart';

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

    final sessionManager = BasicSessionManager();
    final contextManager = BasicContextManager(
      eventBus: eventBus,
      compressors: [
        SummarizingCompressor(model: config.defaultModel),
        const TruncatingCompressor(),
      ],
    );
    final fileSystemManager = BasicFileSystemManager();
    final toolManager = BasicToolManager(tools: initialTools);
    final sandboxManager = BasicSandboxManager(sandboxes: initialSandboxes);
    final activePolicyEngine = policyEngine ?? BasicPolicyEngine(eventBus: eventBus);
    final activeScheduler = scheduler ?? BasicVasterScheduler(taskQueue: PriorityTaskQueue());
    final activeRootBudget = rootBudget ?? ExecutionBudget.unlimited();

    final agentManager = AdvancedAgentManager(
      sessionManager: sessionManager,
      eventBus: eventBus,
      resourceTracker: resourceTracker,
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
      name: 'write_file',
      description: 'Write text content to a file in the virtual filesystem.',
      parametersSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute VFS path'},
          'content': {'type': 'string', 'description': 'Text content to write'},
        },
        'required': ['path', 'content'],
      },
      handler: (args) async {
        final path = args['path']?.toString() ?? '';
        final content = args['content']?.toString() ?? '';
        await vm.fileSystemManager.resolveFileSystem(path).writeText(path, content);
        return {'status': 'ok', 'path': path};
      },
    ));
    vm.registerTool(FunctionTool.define(
      name: 'read_file',
      description: 'Read text content from a file in the virtual filesystem.',
      parametersSchema: const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute VFS path'},
        },
        'required': ['path'],
      },
      handler: (args) async {
        final path = args['path']?.toString() ?? '';
        final content =
            await vm.fileSystemManager.resolveFileSystem(path).readText(path);
        return {'content': content};
      },
    ));

    return vm;
  }

  @override
  ProgramExecutionJob submitProgram(
    VasterProgram program, {
    ExecutionPolicy? policy,
    ExecutionBudget? customBudget,
    TaskPriority priority = TaskPriority.normal,
  }) {
    final jobId = 'job_${_jobs.length + 1}_${program.programName}';
    final jobBudget = customBudget ?? rootBudget.createChildBudget();
    final activePolicy = policy ?? ExecutionPolicy.unlimited;

    final runtime = VasterRuntime(
      vm: this,
      policy: activePolicy,
      budget: jobBudget,
      scheduler: scheduler,
    );

    final job = ProgramExecutionJob(
      jobId: jobId,
      program: program,
      runtime: runtime,
      budget: jobBudget,
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

  @override
  Future<Map<String, RuntimeState>> runScheduledJobs({int stepQuantum = 5}) async {
    _stepQuantum = stepQuantum;
    final results = _quantumResults = <String, RuntimeState>{};
    try {
      while (scheduler.taskQueue.isNotEmpty) {
        await scheduler.runNext();
      }
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
          SummarizingCompressor(model: model),
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

    final request = ModelRequest(
      messages: [ChatMessage.user(promptText)],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints ?? const [],
    );

    final response = await activeModel.generate(request);
    resourceTracker.consumeTokens(
      response.usage.totalTokenCount > 0
          ? response.usage.totalTokenCount
          : (promptText.length ~/ 4) + (response.text.length ~/ 4),
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

    final request = ModelRequest(
      messages: messages,
      tools: tools ?? const [],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints ?? const [],
    );

    final response = await activeModel.generate(request);
    resourceTracker.consumeTokens(
      response.usage.totalTokenCount > 0
          ? response.usage.totalTokenCount
          : response.text.length ~/ 4,
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
    );

    resourceTracker.consumeTokens(
      response.usage.totalTokenCount > 0
          ? response.usage.totalTokenCount
          : (promptText.length ~/ 4) + (response.text.length ~/ 4),
    );

    return response;
  }

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

    final request = ModelRequest(
      messages: [ChatMessage.user(promptText)],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints ?? const [],
    );

    yield* activeModel.generateStream(request);
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
  void mountSandbox(String sandboxId, SandboxLanguage language) {
    registerSandbox(IsolateCodeSandbox(
      descriptor: SandboxDescriptor(
        sandboxId: sandboxId,
        type: 'isolate',
        description: 'ISA Isolate Sandbox',
        supportedLanguages: [language],
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
              SummarizingCompressor(model: activeModel),
              const TruncatingCompressor(),
            ],
          ),
          contextManager,
        ],
        compressors: [
          SummarizingCompressor(model: activeModel),
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

    String targetAgentId = agentId ?? 'default_root_agent';
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
