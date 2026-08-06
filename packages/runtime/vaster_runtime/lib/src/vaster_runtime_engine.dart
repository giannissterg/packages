import 'dart:convert';

import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_machine_state/vaster_machine_state.dart';
import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_tool/vaster_tool.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';
import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_filesystem_local/vaster_filesystem_local.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'cache_hint_tracker.dart';
import 'call_stack.dart';
import 'agent_task_exception.dart';
import 'decision_arbiter.dart';
import 'extract_outcome.dart';
import 'hitl_controller.dart';
import 'machine_context.dart';
import 'machine_phase.dart';
import 'policy_guard.dart';
import 'register_file.dart';
import 'quota_state_adapter.dart';
import 'register_interpolator.dart';
import 'runtime_state.dart';
import 'runtime_status.dart';
import 'tool_call_orchestrator.dart';


/// Observer invoked after each instruction is executed by a [VasterRuntime].
///
/// Fires with the program counter of the instruction that just ran, the
/// instruction itself, and an unmodifiable snapshot of the post-execution
/// register state. Used by tracing/replay tooling (e.g. `vaster_replay`) to
/// build an execution journal. When no observer is set there is zero overhead.
typedef RuntimeStepObserver = void Function(
  int pc,
  VasterInstruction instruction,
  Map<String, Object?> registers,
);

/// Low-Level ISA Execution Runtime consuming [VasterVirtualMachine].
///
/// Acts as a **pure fetch-decode-dispatch loop**. Each responsibility is
/// delegated to a focused collaborator:
///
/// | Collaborator       | Responsibility                                  |
/// |--------------------|--------------------------------------------------|
/// | [RegisterFile]     | Named register I/O and data manipulation ops    |
/// | [CallStack]        | Subroutine activation records                    |
/// | [CacheHintTracker] | JIT context cache hint tracking                 |
/// | [HitlController]   | Human-in-the-Loop lifecycle state machine       |
/// | [PolicyGuard]      | Policy authorization and security traps         |
/// | [ToolCallOrchestrator] | Model ↔ tool conversation loop              |
/// | [ExecutionBudget]   | Time, token, and cost capacity budget tracking  |
/// | [ResourceTracker]  | Program-declared quota enforcement ([SetQuotaOp]) |
/// | [VasterScheduler]  | Opcode scheduling, priorities, and preemption   |
/// | [VasterVirtualMachine] | All VM subsystem access (model, VFS, agents…) |
class VasterRuntime {
  final VasterVirtualMachine vm;
  final ExecutionBudget budget;
  final VasterScheduler scheduler;

  final RegisterFile _registers;
  final CallStack _callStack = CallStack();
  final CacheHintTracker _cacheHints = CacheHintTracker();
  final HitlController _hitl = HitlController();

  /// Enforces the quota the *program itself* declares via [SetQuotaOp]
  /// (compiled from `BudgetScope`), as opposed to [budget], which is the
  /// host-imposed capacity for this runtime. Starts unlimited; each
  /// [SetQuotaOp] replaces the quota and restarts measurement from that
  /// instruction onward. Breaches throw [QuotaExceededException], which
  /// program-level error handlers may recover from — otherwise the machine
  /// traps.
  final ResourceTracker _quotaTracker;


  int _pc = 0;

  /// The machine's execution phase — sealed, data-carrying (a pause holds
  /// its request, a trap holds its report). [_status]/[_lastError] are
  /// projections so the fetch-decode loop reads naturally.
  MachinePhase _phase = const PhaseIdle();
  RuntimeStatus get _status => _phase.asStatus;
  String? get _lastError => _phase.errorDetails;

  /// Optional per-instruction observer for tracing and time-travel replay.
  ///
  /// When set, it is invoked after every executed instruction with the
  /// post-execution register snapshot. Defaults to `null` (no tracing).
  RuntimeStepObserver? stepObserver;

  /// The ambient execution environment (session, model descriptor, program
  /// toolset, error handlers) — componentized machine state.
  final MachineContext _machineContext = MachineContext();

  /// The live model is DERIVED from the descriptor in [_machineContext],
  /// resolved through the VM registry on use — live objects are never
  /// machine state.
  VasterModel? get _activeModel {
    final descriptor = _machineContext.activeModelDescriptor;
    return descriptor == null ? null : vm.modelRegistry.resolveModel(descriptor);
  }

  String? get _activeSessionId => _machineContext.activeSessionId;

  VasterProgram? _currentProgram;

  /// Security boundary: one policy bound to one engine for this runtime's
  /// lifetime, composed by both instruction dispatch and the tool loop.
  final PolicyGuard _policyGuard;

  /// Runtime-layer metering: every model call this runtime pays for charges
  /// the host [budget] and the program [_quotaTracker] through one pipeline.
  /// Charge-only (no event bus) — the VM funnel and agent turns already emit
  /// their own [ModelUsageEvent]s; emitting here would double-count.
  final ModelCallMeter _meter;

  /// Model ↔ tool conversation orchestration, kept out of the fetch-decode
  /// loop as its own single-responsibility collaborator.
  final ToolCallOrchestrator _toolOrchestrator;

  /// Model-steered decision resolution for [DecideOp] — same separation as
  /// the tool orchestrator: the arbiter handles the model conversation, the
  /// engine keeps the control transfer.
  final DecisionArbiter _decisionArbiter;

  /// ISA `${name}` register interpolation (see RegisterInterpolation spec).
  final RegisterInterpolator _interpolator;

  /// Publishes one extraction warning (same pattern as unresolved
  /// interpolation: tolerated at runtime, visible in telemetry).
  void _warnExtract(String code, String message) =>
      vm.eventBus.publish(RuntimeWarningEvent(
        eventId: 'evt_warn_${code}_$_pc',
        code: code,
        message: message,
        pc: _pc,
      ));

  /// Resolves an interpolated instruction field, surfacing unresolvable
  /// references as runtime warnings instead of failing.
  String _interp(String template) => _interpolator.resolve(
        template,
        onMissing: (name) => vm.eventBus.publish(RuntimeWarningEvent(
          eventId: 'evt_warn_interp_$_pc',
          code: 'unresolved_interpolation',
          message:
              'Register "$name" referenced by \${...} is unset at PC $_pc.',
          pc: _pc,
        )),
      );

  /// The full collaborator graph is built here, eagerly and in dependency
  /// order — construction-time ownership (Rule 5), no lazy initialization.
  factory VasterRuntime({
    required VasterVirtualMachine vm,
    required ExecutionPolicy policy,
    required ExecutionBudget budget,
    required VasterScheduler scheduler,
  }) {
    final registers = RegisterFile();
    final quotaTracker = ResourceTracker(quota: ResourceQuota.unlimited);
    final policyGuard = PolicyGuard(engine: vm.policyEngine, policy: policy);
    final meter = ModelCallMeter(
      pricingCatalog: vm.config.pricingCatalog,
      sinks: [BudgetSink(budget), TrackerSink(quotaTracker)],
    );
    return VasterRuntime._(
      vm,
      budget,
      scheduler,
      registers,
      quotaTracker,
      policyGuard,
      meter,
      ToolCallOrchestrator(
        vm: vm,
        meter: meter,
        quotaTracker: quotaTracker,
        guard: policyGuard,
        maxIterations: maxToolIterations,
      ),
      DecisionArbiter(vm: vm, meter: meter),
      RegisterInterpolator(registers: registers),
    );
  }

  VasterRuntime._(
    this.vm,
    this.budget,
    this.scheduler,
    this._registers,
    this._quotaTracker,
    this._policyGuard,
    this._meter,
    this._toolOrchestrator,
    this._decisionArbiter,
    this._interpolator,
  );

  /// The machine's sealed execution phase (pauses carry their request,
  /// traps carry their report).
  MachinePhase get phase => _phase;

  /// Pending human interaction request if status is [RuntimeStatus.pausedForHuman].
  HumanInteractionRequest? get pendingHumanRequest => _hitl.pendingRequest;

  /// Tokens consumed against the program-declared quota (current [SetQuotaOp]
  /// scope). Read-only observability into the quota meter.
  int get quotaConsumedTokens => _quotaTracker.consumedTokens;

  /// Monetary cost consumed against the program-declared quota scope.
  double get quotaConsumedCost => _quotaTracker.consumedCost;

  /// Tool calls recorded against the program-declared quota scope.
  int get quotaConsumedToolCalls => _quotaTracker.toolCallCount;

  /// The program-declared quota currently being enforced.
  ResourceQuota get activeQuota => _quotaTracker.quota;

  /// The machine's state components — THE single registration point.
  ///
  /// Every piece of machine state lives inside one of these; capture is a
  /// fold, restore is a dispatch. Adding state to the machine means adding
  /// a component here — loose fields on the runtime are forbidden (they are
  /// exactly how the first checkpoint silently lost the active session).
  List<MachineStateComponent> get _stateComponents => [
        _registers,
        _callStack,
        _machineContext,
        _hitl,
        QuotaStateAdapter(_quotaTracker),
      ];

  /// The whole machine at this instruction boundary, as pure JSON.
  MachineSnapshot captureSnapshot() =>
      MachineSnapshot.capture(pc: _pc, componentList: _stateComponents);

  /// Restores a previously captured whole-machine snapshot.
  void restoreSnapshot(MachineSnapshot snapshot) {
    _pc = snapshot.pc;
    snapshot.restoreInto(_stateComponents);
  }

  /// Current execution state snapshot.
  RuntimeState get state => RuntimeState(
        pc: _pc,
        status: _status,
        registers: _registers.snapshot(),
        errorDetails: _lastError,
      );

  /// Currently active [VasterProgram] being executed.
  VasterProgram? get currentProgram => _currentProgram;

  /// Immutable snapshot of the live subroutine activation records, outermost
  /// first. Continuation capture must persist this alongside PC and registers:
  /// a machine paused inside a subroutine is defined by *where it will return
  /// to*, not just where it stopped.
  List<ActivationRecord> get callStackSnapshot => _callStack.snapshot();

  /// Sets/writes a register value in the active register file.
  void setRegister(String registerName, Object? value) {
    _registers.write(registerName, value);
  }

  /// Executes a [VasterProgram] until [HaltOp] or error.
  ///
  /// [startPc] is the instruction index to begin at (default `0`).
  ///
  /// [resetState] controls whether prior execution state is cleared before
  /// running. When `true` (the default) the register file, call stack, cache
  /// hints, HITL state, and active session are reset — the correct behavior for
  /// starting a fresh program. Pass `false` to *resume* or *replay* from an
  /// arbitrary [startPc] while preserving already-applied state (registers,
  /// session, cache hints). Reset is now driven solely by this flag and is
  /// independent of [startPc], so a resume that lands on pc `0` no longer
  /// silently wipes applied registers.
  Future<RuntimeState> executeProgram(
    VasterProgram program, {
    int startPc = 0,
    bool resetState = true,
  }) async {
    _currentProgram = program;
    _pc = startPc;
    _phase = const PhaseRunning();
    if (resetState) {
      _machineContext.clear();
      _registers.clear();
      _callStack.clear();
      _cacheHints.clear();
      _hitl.clear();
      _quotaTracker.applyQuota(ResourceQuota.unlimited);
    }
    // Program-header class table: static metadata installed at load, never
    // mutated by executing instructions.
    if (program.contextClasses != null) {
      vm.contextManager
          .installClassTable(ContextClassTable.fromJson(program.contextClasses!));
    }

    return _runLoop(program);
  }

  /// Resumes program execution after receiving a [HumanInteractionResponse].
  Future<RuntimeState> resumeWithHumanResponse(HumanInteractionResponse response) async {
    if (_status != RuntimeStatus.pausedForHuman || _currentProgram == null) {
      throw StateError('Runtime is not paused for human interaction.');
    }
    _pc += _hitl.consume(response: response, registers: _registers);
    _phase = const PhaseRunning();
    return _runLoop(_currentProgram!);
  }

  /// Restores execution from a whole-machine [snapshot] and resumes
  /// [program], optionally consuming [humanResponse] for a pending HITL
  /// request the snapshot carries.
  ///
  /// The snapshot is total: registers, call stack, ambient machine context
  /// (session/model/toolset/handlers), HITL state, and the quota scope all
  /// restore in one dispatch — there is no parameter list to keep in sync
  /// with the machine's actual state.
  Future<RuntimeState> restoreAndResume(
    MachineSnapshot snapshot,
    VasterProgram program, {
    HumanInteractionResponse? humanResponse,
  }) async {
    _currentProgram = program;
    restoreSnapshot(snapshot);

    // Cache hints are derived state — rebuild them from the (restored)
    // context heap's pinned regions instead of serializing tracker
    // internals. Same fingerprints, same hints, zero extra state.
    for (final region in vm.contextManager.regions) {
      if (region.isPinned) {
        _cacheHints.onRegionPinned(region.id, vm.contextManager);
      }
    }

    if (humanResponse != null) {
      _pc += _hitl.consume(response: humanResponse, registers: _registers);
    }

    _phase = const PhaseRunning();
    return _runLoop(program);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal fetch-decode loop
  // ─────────────────────────────────────────────────────────────────────────

  Future<RuntimeState> _runLoop(VasterProgram program) => _execute(program);

  /// The machine's single fetch-decode-dispatch driver.
  ///
  /// [maxSteps] bounds how many instructions retire before the loop returns
  /// with the machine still `running` — the preemption quantum used by
  /// [executeStep]. When null the loop runs until halt, trap, or pause.
  ///
  /// Run-to-completion and time-sliced execution share this one body on
  /// purpose: budget checks, opcode scheduling, observer dispatch, and trap
  /// handling are per-instruction behavior, and a second copy of the loop is a
  /// second place for them to drift apart.
  Future<RuntimeState> _execute(VasterProgram program, {int? maxSteps}) async {
    var executed = 0;
    while (_pc < program.instructions.length &&
        _status == RuntimeStatus.running &&
        (maxSteps == null || executed < maxSteps)) {
      if (budget.isExpired) {
        _phase = PhaseTimedOut(
            reason: 'Execution budget or deadline expired at PC $_pc');
        break;
      }
      final instruction = program.instructions[_pc];
      // Capture the executing PC before dispatch: control-flow ops mutate _pc,
      // and observers must see the instruction's own address.
      final executingPc = _pc;
      try {
        // Program-declared quota deadline: checked at instruction boundaries,
        // recoverable by program error handlers (unlike host budget expiry).
        _quotaTracker.checkDeadline();
        final stopwatch = Stopwatch()..start();
        await scheduler.scheduleOpcode(
          taskName: 'op_${instruction.runtimeType}_$_pc',
          budget: budget,
          action: () => _executeInstruction(instruction),
        );
        stopwatch.stop();
        budget.consumeTime(stopwatch.elapsed);

        stepObserver?.call(executingPc, instruction, _registers.snapshot());

        if (_status == RuntimeStatus.running) _pc++;
        executed++;
      } catch (e, st) {
        if (_handleProgramError(e)) {
          // Journals must not have silent PC gaps: record the faulting
          // instruction with post-recovery state (the handler's error
          // register is already written and the PC points at the catch).
          stepObserver?.call(executingPc, instruction, _registers.snapshot());
          executed++; // recovery consumed a step
          continue;
        }
        _phase = PhaseTrapped(details: _formatTrap(instruction, e, st));
        stepObserver?.call(executingPc, instruction, _registers.snapshot());
        break;
      }
    }
    return _finalize(program);
  }

  /// Program-boundary bookkeeping, shared by every execution entry point.
  ///
  /// Reaching the end of the instruction stream halts the machine, and halting
  /// expires ephemeral + step-scoped context regions. This runs for time-sliced
  /// execution too: a scheduled job that halts mid-quantum must release its
  /// context regions exactly like one that ran to completion.
  RuntimeState _finalize(VasterProgram program) {
    if (_pc >= program.instructions.length && _status == RuntimeStatus.running) {
      _phase = const PhaseHalted();
    }
    if (_status == RuntimeStatus.halted) {
      vm.contextManager
          .pruneLifetimes({ContextLifetime.ephemeral, ContextLifetime.step});
    }
    return state;
  }

  /// Consults the program-level error-handler stack after an instruction
  /// throws. Returns `true` when a handler recovered: the error text lands in
  /// the handler's register and control transfers to its catch block.
  ///
  /// Policy violations are a VM security boundary, not a program-level error —
  /// they always trap regardless of installed handlers.
  bool _handleProgramError(Object error) {
    if (error is StateError && error.message.startsWith('Policy violation')) {
      return false;
    }
    if (_machineContext.errorHandlers.isEmpty) return false;
    final handler = _machineContext.errorHandlers.removeLast();
    _registers.write(handler.errorVar, '$error');
    _pc = handler.targetPc;
    return true;
  }

  /// Formats a VM trap report: the faulting PC, disassembled instruction, and
  /// a register dump — a machine-level panic instead of a bare stack trace.
  String _formatTrap(VasterInstruction instruction, Object error, StackTrace stack) {
    final registers = _registers.snapshot();
    final registerDump = registers.isEmpty
        ? '  (empty)'
        : registers.entries
            .map((e) => '  ${e.key} = ${_truncate('${e.value}')}')
            .join('\n');
    return [
      '── VASTER VM TRAP ──────────────────────────────',
      'fault    : $error',
      'pc       : $_pc',
      'opcode   : ${instruction.opcode.name}',
      'inst     : ${_truncate(jsonEncode(instruction.toJson()))}',
      'session  : ${_activeSessionId ?? '(none)'}',
      'registers:',
      registerDump,
      '── stack ───────────────────────────────────────',
      '$stack',
    ].join('\n');
  }

  static String _truncate(String value, [int max = 200]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';

  /// Compare semantics for [CompareRegisterOp]: numeric when both sides parse
  /// as numbers, lexicographic otherwise. `eq`/`ne` use loose equality so that
  /// `5` and `'5'` (a register set from model text) compare equal.
  static bool _compare(dynamic left, String operator, dynamic right) {
    if (operator == 'eq') return _looseEquals(left, right);
    if (operator == 'ne') return !_looseEquals(left, right);
    final ln = left is num ? left : num.tryParse('$left');
    final rn = right is num ? right : num.tryParse('$right');
    final cmp =
        (ln != null && rn != null) ? ln.compareTo(rn) : '$left'.compareTo('$right');
    return switch (operator) {
      'lt' => cmp < 0,
      'le' => cmp <= 0,
      'gt' => cmp > 0,
      'ge' => cmp >= 0,
      _ => throw StateError(
          'Unknown compare operator "$operator" (expected lt/le/gt/ge/eq/ne).'),
    };
  }

  static bool _looseEquals(dynamic a, dynamic b) {
    if (a == b) return true;
    final an = a is num ? a : num.tryParse('$a');
    final bn = b is num ? b : num.tryParse('$b');
    if (an != null && bn != null) return an == bn;
    return '$a' == '$b';
  }

  /// Executes up to [stepCount] instructions of [program] — one scheduling
  /// quantum — and returns the resulting [RuntimeState].
  ///
  /// The machine is left `running` when the quantum expires mid-program, so the
  /// scheduler can re-dispatch it later from the preserved PC.
  Future<RuntimeState> executeStep(VasterProgram program, {int stepCount = 5}) {
    if (_phase is PhaseIdle) {
      _phase = const PhaseRunning();
    }
    _currentProgram = program;
    return _execute(program, maxSteps: stepCount);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispatch table — each arm delegates to the correct owner (≤3 lines each)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _executeInstruction(VasterInstruction inst) async {
    switch (inst) {
      // ── Model / LLM ───────────────────────────────────────────────────────
      case PromptOp op:
        // Typed invocation: a responseSchema on the op lowers to the model
        // request's structured-output config (compiler-emitted return type).
        final promptConfig = op.responseSchema == null
            ? null
            : GenerationConfig(responseSchema: op.responseSchema);
        final promptText = _interp(op.promptText);
        var response = _activeSessionId != null
            ? await vm.promptInSession(
                _activeSessionId!,
                promptText,
                model: _activeModel,
                config: promptConfig,
                cacheHints: _cacheHints.activeHints,
              )
            : await vm.prompt(
                promptText,
                model: _activeModel,
                config: promptConfig,
                cacheHints: _cacheHints.activeHints,
              );
        if (response.functionCalls.isNotEmpty) {
          response = await _toolOrchestrator.resolve(
            prompt: promptText,
            initialResponse: response,
            programToolSet: _machineContext.programToolSet,
            model: _activeModel,
            cacheHints: _cacheHints.activeHints,
          );
        }
        // Charge real server-reported usage; the labeled estimate is only a
        // fallback for backends that don't report tokens.
        _meter.charge(
          usage: response.usage.totalTokenCount > 0
              ? response.usage
              : TokenEstimate.forExchange(
                  prompt: promptText, output: response.text),
          modelName: (_activeModel ?? vm.config.defaultModel).modelName,
          callSite: 'isa_prompt',
        );
        if (op.outputVar != null) _registers.write(op.outputVar!, response.text);

      case SelectModelOp op:
        _machineContext.activeModelDescriptor = op.descriptor;

      case CreateSessionOp op:
        await vm.createSession(
          sessionId: op.sessionId,
          modelDescriptor: op.modelDescriptor,
        );

      case SetSessionOp op:
        _machineContext.activeSessionId = op.sessionId;

      case CheckPolicyOp op:
        _checkPolicy(op.action, op.resource);

      // ── Filesystem ────────────────────────────────────────────────────────
      case MountFsOp op:
        // Declared disk mounts get a real local filesystem — a memory mount
        // silently standing in for a declared diskPath is a fidelity bug.
        vm.mountFileSystem(
          op.mountPrefix,
          op.diskPath != null
              ? LocalVasterFileSystem(op.diskPath!, mountPrefix: op.mountPrefix)
              : MemoryVasterFileSystem(),
        );

      case WriteFileOp op:
        // Paths interpolate before the policy check: policy evaluates the
        // resolved path (RegisterInterpolation spec).
        final writePath = _interp(op.vfsPath);
        _checkPolicy(PolicyAction.fileWrite, writePath);
        final fs = vm.fileSystemManager.resolveFileSystem(writePath);
        await fs.writeText(writePath, _interp(op.content));

      case ReadFileOp op:
        final readPath = _interp(op.vfsPath);
        _checkPolicy(PolicyAction.fileRead, readPath);
        final fs = vm.fileSystemManager.resolveFileSystem(readPath);
        final content = await fs.readText(readPath);
        if (op.outputVar != null) _registers.write(op.outputVar!, content);

      case BeginTransactionOp _:
        await vm.fileSystemManager.beginTransaction();

      case CommitOp _:
        await vm.fileSystemManager.commit();

      case RollbackOp _:
        await vm.fileSystemManager.rollback();

      // ── Sandbox ───────────────────────────────────────────────────────────
      case RegisterSandboxOp op:
        vm.mountSandbox(
          op.sandboxId,
          op.language,
          timeout: op.timeoutMs == null
              ? null
              : Duration(milliseconds: op.timeoutMs!),
        );

      case ExecSandboxOp op:
        _checkPolicy(PolicyAction.sandboxExec, op.sandboxId);
        final sandboxClock = Stopwatch()..start();
        final result = await vm.sandboxManager.runCode(
          sandboxId: op.sandboxId,
          codeOrCommand: _interp(op.code),
        );
        sandboxClock.stop();
        final languages =
            vm.sandboxManager.getSandbox(op.sandboxId)?.descriptor.supportedLanguages;
        vm.eventBus.publish(SandboxExecutedEvent(
          eventId: 'evt_sandbox_exec_${op.sandboxId}_$_pc',
          sandboxId: op.sandboxId,
          language:
              (languages == null || languages.isEmpty) ? 'unknown' : languages.first.name,
          exitCode: result.exitCode,
          executionDuration: sandboxClock.elapsed,
        ));
        if (op.outputVar != null) _registers.write(op.outputVar!, result.stdout);

      // ── Agents ────────────────────────────────────────────────────────────
      case CreateAgentOp op:
        await vm.createAgent(descriptor: op.descriptor);

      case DispatchAgentTaskOp op:
        final meta = <String, dynamic>{
          if (_cacheHints.isEmpty == false)
            'cacheHints': _cacheHints.activeHints.map((h) => h.toJson()).toList(),
          // Typed invocation: forwarded to the agent's ModelRequest.
          if (op.responseSchema != null) 'responseSchema': op.responseSchema,
        };
        final taskPrompt = _interp(op.taskPrompt);
        final output = await vm.runAgentTask(
          AgentTask(taskId: 'isa_task_$_pc', inputPrompt: taskPrompt, metadata: meta),
          agentId: op.agentId,
        );
        // Charge the task tree's real accumulated usage (agent + subagents);
        // the estimate only stands in when the whole tree reported nothing.
        // Wire-reported cost (summed across the tree) wins; else the meter
        // rates the default model, which agents run on unless configured.
        final taskUsage = output.aggregateUsage;
        _meter.charge(
          usage: taskUsage.totalTokenCount > 0
              ? taskUsage
              : TokenEstimate.forExchange(
                  prompt: taskPrompt, output: output.outputText),
          modelName: vm.config.defaultModel.modelName,
          callSite: 'isa_agent_task',
        );
        // The sibling outcome register carries the sealed outcome's KIND
        // (ABI convention: taskOutcomeRegister) — observable data even
        // when a handler recovers the failure.
        if (op.outputVar != null) {
          _registers.write(
              taskOutcomeRegister(op.outputVar!), output.outcome.kind);
        }
        // Failure is a program error, not an empty register: route it to
        // the error-handler stack (TryCatch / Resilient) or trap. This is
        // what makes agent failures recoverable at all.
        if (!output.isSuccess) {
          throw AgentTaskException(
            agentId: op.agentId,
            taskId: output.taskId,
            outcome: output.outcome,
          );
        }
        if (op.outputVar != null) _registers.write(op.outputVar!, output.outputText);

      case DispatchParallelTasksOp op:
        // Each dispatch gets its own taskId — a shared id would collide in
        // event streams and output correlation across the parallel batch.
        final dispatches = [
          for (var i = 0; i < op.dispatches.length; i++)
            (
              agentId: op.dispatches[i].agentId,
              task: AgentTask(
                  taskId: 'parallel_${_pc}_$i',
                  inputPrompt: _interp(op.dispatches[i].taskPrompt)),
            ),
        ];
        final outputs =
            await vm.agentManager.dispatchParallelTasks(dispatches);
        // Parallel work is not free work: charge the summed usage of every
        // task tree (previously this path charged nothing at all).
        var parallelUsage = const UsageMetadata();
        AgentTaskException? firstFailure;
        for (int i = 0; i < outputs.length; i++) {
          parallelUsage += outputs[i].aggregateUsage;
          final v = op.dispatches[i].outputVar;
          if (v != null) {
            _registers.write(taskOutcomeRegister(v), outputs[i].outcome.kind);
            if (outputs[i].isSuccess) {
              _registers.write(v, outputs[i].outputText);
            }
          }
          if (!outputs[i].isSuccess) {
            firstFailure ??= AgentTaskException(
              agentId: op.dispatches[i].agentId,
              taskId: outputs[i].taskId,
              outcome: outputs[i].outcome,
            );
          }
        }
        _meter.charge(
          usage: parallelUsage,
          modelName: vm.config.defaultModel.modelName,
          callSite: 'isa_parallel_tasks',
        );
        // Every sibling outcome register is written first (successes keep
        // their outputs), THEN the first failure raises — a handler sees
        // the whole batch's outcomes.
        if (firstFailure != null) throw firstFailure;

      case SendMessageOp op:
        vm.messagingHub.sendMessage(AgentMessage(
          messageId: 'isa_msg_$_pc',
          senderAgentId: op.senderId,
          recipientAgentId: op.recipientId,
          payload: _interpolator.resolveMap(op.payload,
              onMissing: (name) => vm.eventBus.publish(RuntimeWarningEvent(
                    eventId: 'evt_warn_interp_$_pc',
                    code: 'unresolved_interpolation',
                    message: 'Register "$name" referenced by \${...} is '
                        'unset at PC $_pc.',
                    pc: _pc,
                  ))),
        ));

      case PopMessageOp op:
        final msg = vm.messagingHub.popNextMessage(op.agentId);
        if (op.outputVar != null) {
          final payloadStr = msg?.payload['text']?.toString() ?? msg?.payload.toString() ?? '';
          _registers.write(op.outputVar!, payloadStr);
        }

      // ── Session / Context ─────────────────────────────────────────────────
      case ForkSessionOp op:
        final source = vm.sessionManager.getSession(op.sourceSessionId);
        if (source != null) {
          final forked = source.fork(newSessionId: op.targetSessionId);
          vm.sessionManager.registerSession(op.targetSessionId, forked);
        }

      case PinContextOp op:
        vm.contextManager.pinRegion(op.regionId);
        _cacheHints.onRegionPinned(op.regionId, vm.contextManager);

      case AddContextOp op:
        final content = op.sourceVar != null
            ? (_registers.read(op.sourceVar!)?.toString() ?? '')
            : _interp(op.text);
        vm.contextManager.addRegion(ContextRegion.text(
          id: op.regionId,
          label: op.label,
          role: Role.user,
          text: content,
          classId: op.className,
          // Null policy fields inherit from the region's context class.
          priority:
              op.priority != null ? ContextPriority.parse(op.priority!) : null,
          lifetime:
              op.lifetime != null ? ContextLifetime.parse(op.lifetime!) : null,
          compressibility: op.compressibility != null
              ? ContextCompressibility.parse(op.compressibility!)
              : null,
          isPinned: op.pinned,
        ));
        if (op.pinned) {
          _cacheHints.onRegionPinned(op.regionId, vm.contextManager);
        }

      case EvictContextOp op:
        final removed =
            vm.contextManager.removeRegion(op.regionId, force: op.force);
        if (removed) _cacheHints.removeHint(op.regionId);

      case UnpinContextOp op:
        vm.contextManager.unpinRegion(op.regionId);
        _cacheHints.removeHint(op.regionId);

      case SetContextPolicyOp op:
        vm.contextManager.updateRegion(
          op.regionId,
          (r) => r.copyWith(
            priority:
                op.priority != null ? ContextPriority.parse(op.priority) : null,
            isPinned: op.pinned,
            compressibility: op.compressibility != null
                ? ContextCompressibility.parse(op.compressibility)
                : null,
            utility: op.utility,
          ),
        );
        if (op.pinned == true) {
          _cacheHints.onRegionPinned(op.regionId, vm.contextManager);
        } else if (op.pinned == false) {
          _cacheHints.removeHint(op.regionId);
        }

      case CompressContextOp op:
        final target = op.targetTokens ??
            (_activeModel ?? vm.config.defaultModel)
                    .capabilities.maxContextTokens *
                9 ~/
                10;
        final report = await vm.contextManager.compact(
          targetTokens: target,
          regionId: op.regionId,
          includePinned: true,
        );
        // Compressed pinned regions changed content: refresh their hints so
        // prompt-cache/KV lowering never serves stale fingerprints.
        for (final entry in report.entries) {
          final region = vm.contextManager.getRegion(entry.regionId);
          if (region != null && region.isPinned) {
            _cacheHints.onRegionPinned(entry.regionId, vm.contextManager);
          }
        }
        if (op.outputVar != null) {
          _registers.write(op.outputVar!, report.tokensFreed.toString());
        }

      case RegisterToolSetOp op:
        _machineContext.programToolSet = op.tools;
        for (final tool in op.tools) {
          if (tool.name == 'write_file') {
            vm.toolManager.registerTool(
              FunctionTool.define(
                name: 'write_file',
                description: tool.description,
                parametersSchema: tool.parametersSchema,
                handler: (args) async {
                  final path = args['path']?.toString() ?? '';
                  final content = args['content']?.toString() ?? '';
                  final fs = vm.fileSystemManager.resolveFileSystem(path);
                  await fs.writeText(path, content);
                  return {'result': 'Successfully wrote to $path'};
                },
              ),
            );
          } else if (tool.name == 'read_file') {
            vm.toolManager.registerTool(
              FunctionTool.define(
                name: 'read_file',
                description: tool.description,
                parametersSchema: tool.parametersSchema,
                handler: (args) async {
                  final path = args['path']?.toString() ?? '';
                  final fs = vm.fileSystemManager.resolveFileSystem(path);
                  final content = await fs.readText(path);
                  return {'content': content};
                },
              ),
            );
          } else {
            vm.toolManager.registerTool(
              FunctionTool.define(
                name: tool.name,
                description: tool.description,
                parametersSchema: tool.parametersSchema,
                handler: (args) async => {'result': 'Tool ${tool.name} executed successfully.'},
              ),
            );
          }
        }

      case SetQuotaOp op:
        _quotaTracker.applyQuota(op.quota);
        if (op.quota.maxCostBudget != null) {
          // A cost ceiling binds only when the active backend wire-reports
          // cost or the pricing catalog rates its model — otherwise declare
          // the gap loudly instead of pretending.
          final costModel = _activeModel ?? vm.config.defaultModel;
          final enforceable = costModel.capabilities.reportsCostUsd ||
              vm.config.pricingCatalog.prices(costModel.modelName);
          if (!enforceable) {
            vm.eventBus.publish(RuntimeWarningEvent(
              eventId: 'evt_warn_quota_cost_$_pc',
              code: 'cost_quota_unenforced',
              message: 'maxCostBudget is declared at PC $_pc but the active '
                  'backend "${costModel.modelName}" neither reports cost nor '
                  'has catalog pricing — the cost ceiling is not enforced.',
              pc: _pc,
            ));
          }
        }

      // ── HITL ─────────────────────────────────────────────────────────────
      case YieldHumanInteractionOp op:
        final request = RegisterInterpolation.mentions(op.request.prompt)
            ? HumanInteractionRequest(
                requestId: op.request.requestId,
                type: op.request.type,
                prompt: _interp(op.request.prompt),
                options: op.request.options,
                outputVar: op.request.outputVar,
                timeoutMs: op.request.timeoutMs,
              )
            : op.request;
        _hitl.pause(request: request, eventBus: vm.eventBus, currentPc: _pc);
        _phase = PhasePausedForHuman(request: request);

      // ── Control flow ──────────────────────────────────────────────────────
      case CallOp op:
        _registers.writeAll(op.arguments);
        _callStack.push(ActivationRecord(
          functionName: op.functionName,
          returnPc: _pc + 1,
          outputVar: op.outputVar,
        ));
        _pc = op.targetPc - 1;

      case ReturnSubroutineOp op:
        if (_callStack.isEmpty) {
          _phase = const PhaseHalted();
        } else {
          final frame = _callStack.pop();
          if (op.returnRegister != null && frame.outputVar != null) {
            _registers.write(frame.outputVar!, _registers.read(op.returnRegister!));
          }
          _pc = frame.returnPc - 1;
        }

      case JumpOp op:
        _pc = op.targetPc - 1;

      case JumpIfOp op:
        final val = _registers.read(op.conditionVar);
        final isTrue = switch (val) {
          true || 'true' => true,
          false || 'false' || '' || 0 || null => false,
          _ => true,
        };
        if (isTrue) _pc = op.targetPc - 1;

      case DecideOp op:
        if (op.branches.isEmpty) {
          throw StateError('DecideOp at PC $_pc has no branches.');
        }
        final outcome = await _decisionArbiter.decide(
          prompt: _interp(op.prompt),
          branches: [
            for (final b in op.branches)
              (label: b.label, description: b.description),
          ],
          model: _activeModel,
          sessionId: _activeSessionId,
          cacheHints: _cacheHints.activeHints,
        );
        final chosenLabel = outcome.label ?? op.defaultLabel;
        DecisionBranch? branch;
        for (final b in op.branches) {
          if (b.label == chosenLabel) {
            branch = b;
            break;
          }
        }
        if (branch == null) {
          throw StateError(
              'DecideOp at PC $_pc: model output did not resolve to a branch '
              'label (${op.branches.map((b) => b.label).join(', ')}) and no '
              'valid defaultLabel is set.');
        }
        if (op.outputVar != null) {
          _registers.write(op.outputVar!, branch.label);
          if (outcome.rationale != null) {
            _registers.write(
                decideRationaleRegister(op.outputVar!), outcome.rationale);
          }
        }
        vm.eventBus.publish(DecisionMadeEvent(
          eventId: 'evt_decide_$_pc',
          chosenLabel: branch.label,
          rationale: outcome.rationale,
          branchCount: op.branches.length,
          targetPc: branch.targetPc,
          usedDefault: outcome.label == null,
        ));
        _pc = branch.targetPc - 1;

      case PushErrorHandlerOp op:
        _machineContext.errorHandlers.add(
            ErrorHandlerFrame(targetPc: op.targetPc, errorVar: op.errorVar));

      case PopErrorHandlerOp _:
        if (_machineContext.errorHandlers.isNotEmpty) _machineContext.errorHandlers.removeLast();

      // ── Register file ─────────────────────────────────────────────────────
      case SetRegisterOp op:
        _registers.write(op.registerName, op.value);

      case IncrementRegisterOp op:
        final current = _registers.read(op.registerName);
        final base = current is num ? current : (num.tryParse('$current') ?? 0);
        _registers.write(op.registerName, base + op.delta);

      case CompareRegisterOp op:
        final left = _registers.read(op.leftVar);
        final right =
            op.rightVar != null ? _registers.read(op.rightVar!) : op.rightValue;
        _registers.write(op.targetVar, _compare(left, op.operator, right));

      case JsonExtractOp op:
        // Tolerant but observable: a failed extraction never traps (model
        // output is untrusted), but each failure shape publishes a typed
        // warning at the point of failure instead of surfacing later as a
        // mystery unresolved interpolation.
        final outcome = _registers.jsonExtract(
          sourceVar: op.sourceVar,
          jsonKey: op.jsonKey,
          targetVar: op.targetVar,
        );
        switch (outcome) {
          case ExtractOk():
            break;
          case ExtractSourceMissing(:final sourceVar):
            _warnExtract('extract_source_missing',
                'JsonExtract source register "$sourceVar" is unset.');
          case ExtractParseFailure(:final sourceVar, :final detail):
            _warnExtract('extract_parse_error',
                'JsonExtract source "$sourceVar" is not a JSON object: $detail');
          case ExtractKeyMissing(
              :final sourceVar,
              :final jsonKey,
              :final availableKeys
            ):
            _warnExtract(
                'extract_key_missing',
                'JsonExtract key "$jsonKey" not found in "$sourceVar" '
                '(available: ${availableKeys.join(', ')}).');
        }

      case ConcatRegisterOp op:
        _registers.concat(targetVar: op.targetVar, sourceVars: op.sourceVars);

      case HaltOp _:
        _phase = const PhaseHalted();
    }
  }


  /// Currently active tool definitions registered in this runtime context.
  List<ToolDefinition> get activeToolSet => List.unmodifiable(_machineContext.programToolSet);

  /// Maximum model turns in one tool-calling loop (runaway guard).
  static const int maxToolIterations = 8;

  void _checkPolicy(PolicyAction action, String resource) =>
      _policyGuard.check(action, resource);
}
