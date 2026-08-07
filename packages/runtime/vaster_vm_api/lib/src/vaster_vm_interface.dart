import 'package:vaster_agent_manager/vaster_agent_manager.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'model_registry.dart';
import 'sandbox_registration.dart';
import 'prompt_funnel.dart';
import 'tool_loop_host.dart';
import 'vm_config.dart';
import 'vm_shutdown_report.dart';

/// Master interface defining the top-level LLM Virtual Machine.
///
/// Capability facets carve narrow views out of this master interface:
/// [PromptFunnel] (the model-turn verbs) and [ToolLoopHost] (what the
/// runtime's tool loop needs). Collaborators with a bounded job depend on
/// a facet, not on this master one — the type then documents what the
/// component can actually do.
abstract interface class VasterVirtualMachine
    implements PromptFunnel, ToolLoopHost {
  /// VM configuration settings.
  VMConfig get config;

  /// Active Session Manager.
  SessionManager get sessionManager;

  /// Active Context Manager.
  ContextManager get contextManager;

  /// Ergonomic context-management facade over [contextManager]:
  /// inspect, add, remove, update, prioritize, pin, compress, expand.
  ContextWorkspace get contextWorkspace;

  /// Active Code Sandbox Manager.
  SandboxManager get sandboxManager;

  /// Active Multi-Agent Supervisor Manager.
  AgentManager get agentManager;

  /// The agent-loop effect-recorder binding (GAP-3a): agents hold it
  /// eagerly at construction; the executing runtime binds its idempotency
  /// ledger's adapter into it so agent-internal tool calls replay across
  /// retry attempts instead of re-executing side effects. Unbound, it is
  /// a no-op — agents execute directly.
  ToolEffectRecorderBinding get agentToolRecorder;

  /// The agent-loop tool-call gate binding (A1): agents pass every tool
  /// call through it; the executing runtime binds the PROGRAM's policy
  /// guard here, so agent-internal tool calls answer to the same
  /// execution policy the ISA loop enforces. Unbound, it permits.
  ToolCallGateBinding get agentToolGate;

  /// Active Inter-Agent Messaging Hub.
  AgentMessagingHub get messagingHub;

  /// Active Resource Tracker.
  ResourceTracker get resourceTracker;

  /// Active Model Registry.
  ModelRegistry get modelRegistry;

  /// Active Security Policy Engine.
  PolicyEngine get policyEngine;

  /// Active Instruction Scheduler.
  VasterScheduler get scheduler;

  /// Root VM Execution Budget.
  ExecutionBudget get rootBudget;

  /// Registers a concrete [VasterModel] for a given [ModelDescriptor];
  /// returns the model it displaced under the descriptor key, null when
  /// fresh.
/// Registers a model and returns every binding it displaced, keyed by
  /// the slot (descriptor key and/or provider — registration writes both).
  Map<String, VasterModel> registerModel(
      ModelDescriptor descriptor, VasterModel model);

  /// Creates a new model session in [sessionManager].
  ///
  /// **Contract — layered context**: the session's manager layers a
  /// private manager (history, session-local regions) over the VM-wide
  /// one, so ambient pinned regions remain visible to session prompts
  /// exactly as they are to sessionless ones. Agents receive the same
  /// layering.
  Future<ModelSession> createSession({
    required String sessionId,
    ModelDescriptor? modelDescriptor,
  });

  /// Mounts a filesystem backend into [fileSystemManager] and bridges
  /// files to context; returns the normalized mount prefix.
  String mountFileSystem(String pathPrefix, VasterFileSystem fs);

  /// Registers an [ExecutableTool] into [toolManager]; returns the
  /// same-name tool it displaced, null when fresh.
  ExecutableTool? registerTool(ExecutableTool tool);

  /// Registers a [CodeSandbox] into [sandboxManager] and bridges it into
  /// an [ExecutableTool]; returns what each registration displaced (the
  /// bridge writes two registries, so one return value could only ever
  /// report half of it).
  SandboxRegistration registerSandbox(CodeSandbox sandbox);

  /// Constructs and registers a default isolate-backed [CodeSandbox] for [sandboxId]
  /// supporting [language]. This is a factory convenience so the runtime does not
  /// need to depend on concrete sandbox implementations.
  /// Returns the sandbox it constructed and registered — previously
  /// unreachable by the caller (Rule 11's handle idiom).
  CodeSandbox mountSandbox(String sandboxId, SandboxLanguage language,
      {Duration? timeout});

  /// Creates and registers an autonomous agent in [agentManager].
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    VasterModel? model,
    String? parentAgentId,
  });

  /// Agent provisioned on demand when [runAgentTask] is called with no
  /// [agentId] — the VM's general-purpose root agent. Named here so the
  /// get-or-create fallback is a documented ABI convention, not a magic
  /// string buried in the engine.
  static const String defaultRootAgentId = 'default_root_agent';

  /// Dispatches an agent task and enforces resource quotas.
  ///
  /// With no [agentId], the task goes to [defaultRootAgentId], which is
  /// created on first use.
  Future<AgentOutput> runAgentTask(
    AgentTask task, {
    String? agentId,
  });

  /// Shuts down VM resources cleanly; returns the teardown report —
  /// what was actually closed (Rule 11).
  Future<VmShutdownReport> shutdown();
}
