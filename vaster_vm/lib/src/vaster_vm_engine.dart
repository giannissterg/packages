import 'dart:async';
import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'model_registry.dart';
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
  });

  /// Factory bootstrap method to create a fully configured [VasterVMEngine].
  static Future<VasterVMEngine> bootstrap({
    required VMConfig config,
    VasterFileSystem? rootFileSystem,
    List<ExecutableTool>? initialTools,
    List<CodeSandbox>? initialSandboxes,
  }) async {
    final eventBus = BasicEventBus();
    final messagingHub = BasicAgentMessagingHub();
    final resourceTracker = ResourceTracker(quota: config.defaultQuota);

    final sessionManager = BasicSessionManager();
    final contextManager = BasicContextManager();
    final fileSystemManager = BasicFileSystemManager();
    final toolManager = BasicToolManager(tools: initialTools);
    final sandboxManager = BasicSandboxManager(sandboxes: initialSandboxes);

    final agentManager = AdvancedAgentManager(
      sessionManager: sessionManager,
      eventBus: eventBus,
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
    );

    // Automatic Bridge 1: Mount root filesystem if provided, or default MemoryVasterFileSystem
    final rootFs = rootFileSystem ?? MemoryVasterFileSystem();
    vm.mountFileSystem(config.rootMountPath, rootFs);

    // Automatic Bridge 2: Register initial sandboxes into ToolManager
    if (initialSandboxes != null) {
      for (final sb in initialSandboxes) {
        vm.registerSandbox(sb);
      }
    }

    return vm;
  }

  @override
  Future<ModelResponse> prompt(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    resourceTracker.checkDeadline();
    final activeModel = model ?? this.config.defaultModel;

    final request = ModelRequest(
      messages: [ChatMessage.user(promptText)],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
    );

    final response = await activeModel.generate(request);
    resourceTracker.consumeTokens(
      (promptText.length ~/ 4) + (response.text.length ~/ 4),
    );

    return response;
  }

  @override
  Stream<ModelResponseChunk> promptStream(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
  }) async* {
    cancelToken?.throwIfCancelled();
    resourceTracker.checkDeadline();
    final activeModel = model ?? this.config.defaultModel;

    final request = ModelRequest(
      messages: [ChatMessage.user(promptText)],
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
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
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    VasterModel? model,
    String? parentAgentId,
  }) async {
    final activeModel = model ?? config.defaultModel;

    return await agentManager.createAgent(
      descriptor: descriptor,
      model: activeModel,
      contextManager: contextManager,
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
