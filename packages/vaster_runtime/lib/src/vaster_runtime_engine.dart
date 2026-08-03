import 'dart:convert';

import 'package:vaster_vm/vaster_vm.dart';


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
/// | [VasterScheduler]  | Opcode scheduling, priorities, and preemption   |
/// | [VasterVirtualMachine] | All VM subsystem access (model, VFS, agents…) |
class VasterRuntime {
  final VasterVirtualMachine vm;
  final ExecutionBudget budget;
  final VasterScheduler scheduler;

  final RegisterFile _registers = RegisterFile();
  final CallStack _callStack = CallStack();
  final CacheHintTracker _cacheHints = CacheHintTracker();
  final HitlController _hitl = HitlController();

  /// Program-level error handlers installed by [PushErrorHandlerOp]
  /// (innermost last). Consulted by both run loops when an instruction
  /// throws; policy violations bypass this stack entirely.
  final List<({int targetPc, String errorVar})> _errorHandlers = [];

  int _pc = 0;
  RuntimeStatus _status = RuntimeStatus.idle;
  String? _lastError;

  /// Optional per-instruction observer for tracing and time-travel replay.
  ///
  /// When set, it is invoked after every executed instruction with the
  /// post-execution register snapshot. Defaults to `null` (no tracing).
  RuntimeStepObserver? stepObserver;

  VasterModel? _activeModel;
  String? _activeSessionId;
  final ExecutionPolicy _activePolicy;
  VasterProgram? _currentProgram;

  /// Security boundary: one policy bound to one engine for this runtime's
  /// lifetime, composed by both instruction dispatch and the tool loop.
  late final PolicyGuard _policyGuard =
      PolicyGuard(engine: vm.policyEngine, policy: _activePolicy);

  /// Model ↔ tool conversation orchestration, kept out of the fetch-decode
  /// loop as its own single-responsibility collaborator.
  late final ToolCallOrchestrator _toolOrchestrator = ToolCallOrchestrator(
    vm: vm,
    budget: budget,
    guard: _policyGuard,
    maxIterations: maxToolIterations,
  );

  /// Model-steered decision resolution for [DecideOp] — same separation as
  /// the tool orchestrator: the arbiter handles the model conversation, the
  /// engine keeps the control transfer.
  late final DecisionArbiter _decisionArbiter =
      DecisionArbiter(vm: vm, budget: budget);

  VasterRuntime({
    required this.vm,
    required ExecutionPolicy policy,
    required this.budget,
    required this.scheduler,
  }) : _activePolicy = policy;

  /// Pending human interaction request if status is [RuntimeStatus.pausedForHuman].
  HumanInteractionRequest? get pendingHumanRequest => _hitl.pendingRequest;

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
    _status = RuntimeStatus.running;
    _lastError = null;
    if (resetState) {
      _activeSessionId = null;
      _registers.clear();
      _callStack.clear();
      _cacheHints.clear();
      _hitl.clear();
      _errorHandlers.clear();
    }

    return _runLoop(program);
  }

  /// Resumes program execution after receiving a [HumanInteractionResponse].
  Future<RuntimeState> resumeWithHumanResponse(HumanInteractionResponse response) async {
    if (_status != RuntimeStatus.pausedForHuman || _currentProgram == null) {
      throw StateError('Runtime is not paused for human interaction.');
    }
    _pc += _hitl.consume(response: response, registers: _registers);
    _status = RuntimeStatus.running;
    return _runLoop(_currentProgram!);
  }

  /// Restores execution from a continuation snapshot and resumes the program.
  ///
  /// [callStack] restores the subroutine activation records captured at
  /// suspension (outermost first); omitting it resumes with an empty stack,
  /// which is only correct for a machine suspended at top level.
  Future<RuntimeState> restoreAndResume(
    int resumePc,
    VasterProgram program, {
    Map<String, dynamic>? registers,
    List<ActivationRecord>? callStack,
    HumanInteractionRequest? pendingRequest,
    HumanInteractionResponse? humanResponse,
  }) async {
    _currentProgram = program;
    _pc = resumePc;
    if (registers != null) _registers.restore(registers);
    if (callStack != null) _callStack.restore(callStack);
    _hitl.restorePending(pendingRequest);

    if (humanResponse != null) {
      _pc += _hitl.consume(response: humanResponse, registers: _registers);
    }

    _status = RuntimeStatus.running;
    _lastError = null;
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
        _status = RuntimeStatus.timedOut;
        _lastError = 'Execution budget or deadline expired at PC $_pc';
        break;
      }
      final instruction = program.instructions[_pc];
      // Capture the executing PC before dispatch: control-flow ops mutate _pc,
      // and observers must see the instruction's own address.
      final executingPc = _pc;
      try {
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
          executed++; // recovery consumed a step
          continue;
        }
        _status = RuntimeStatus.error;
        _lastError = _formatTrap(instruction, e, st);
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
      _status = RuntimeStatus.halted;
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
    if (_errorHandlers.isEmpty) return false;
    final handler = _errorHandlers.removeLast();
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
    if (_status == RuntimeStatus.idle) {
      _status = RuntimeStatus.running;
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
        var response = _activeSessionId != null
            ? await vm.promptInSession(
                _activeSessionId!,
                op.promptText,
                model: _activeModel,
                config: promptConfig,
                cacheHints: _cacheHints.activeHints,
              )
            : await vm.prompt(
                op.promptText,
                model: _activeModel,
                config: promptConfig,
                cacheHints: _cacheHints.activeHints,
              );
        if (response.functionCalls.isNotEmpty) {
          response = await _toolOrchestrator.resolve(
            prompt: op.promptText,
            initialResponse: response,
            programToolSet: _activeToolSet,
            model: _activeModel,
            cacheHints: _cacheHints.activeHints,
          );
        }
        // Charge real server-reported usage; the length heuristic is only a
        // fallback for backends that don't report tokens.
        final tokens = response.usage.totalTokenCount > 0
            ? response.usage.totalTokenCount
            : (op.promptText.length ~/ 4) + (response.text.length ~/ 4);
        budget.consumeTokens(tokens);
        if (op.outputVar != null) _registers.write(op.outputVar!, response.text);

      case SelectModelOp op:
        _activeModel = vm.modelRegistry.resolveModel(op.descriptor);

      case CreateSessionOp op:
        await vm.createSession(
          sessionId: op.sessionId,
          modelDescriptor: op.modelDescriptor,
        );

      case SetSessionOp op:
        _activeSessionId = op.sessionId;

      case CheckPolicyOp op:
        _checkPolicy(op.action, op.resource);

      // ── Filesystem ────────────────────────────────────────────────────────
      case MountFsOp op:
        vm.mountFileSystem(op.mountPrefix, MemoryVasterFileSystem());

      case WriteFileOp op:
        _checkPolicy(PolicyAction.fileWrite, op.vfsPath);
        final fs = vm.fileSystemManager.resolveFileSystem(op.vfsPath);
        await fs.writeText(op.vfsPath, op.content);

      case ReadFileOp op:
        _checkPolicy(PolicyAction.fileRead, op.vfsPath);
        final fs = vm.fileSystemManager.resolveFileSystem(op.vfsPath);
        final content = await fs.readText(op.vfsPath);
        if (op.outputVar != null) _registers.write(op.outputVar!, content);

      case BeginTransactionOp _:
        await vm.fileSystemManager.beginTransaction();

      case CommitOp _:
        await vm.fileSystemManager.commit();

      case RollbackOp _:
        await vm.fileSystemManager.rollback();

      // ── Sandbox ───────────────────────────────────────────────────────────
      case RegisterSandboxOp op:
        vm.mountSandbox(op.sandboxId, op.language);

      case ExecSandboxOp op:
        _checkPolicy(PolicyAction.sandboxExec, op.sandboxId);
        final sandboxClock = Stopwatch()..start();
        final result = await vm.sandboxManager.runCode(
          sandboxId: op.sandboxId,
          codeOrCommand: op.code,
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
        final output = await vm.runAgentTask(
          AgentTask(taskId: 'isa_task_$_pc', inputPrompt: op.taskPrompt, metadata: meta),
          agentId: op.agentId,
        );
        final tokens = (op.taskPrompt.length ~/ 4) + (output.outputText.length ~/ 4);
        budget.consumeTokens(tokens);
        if (op.outputVar != null) _registers.write(op.outputVar!, output.outputText);

      case DispatchParallelTasksOp op:
        if (vm.agentManager is AdvancedAgentManager) {
          final manager = vm.agentManager as AdvancedAgentManager;
          final dispatches = op.dispatches
              .map((d) => (
                    agentId: d.agentId,
                    task: AgentTask(taskId: 'parallel_$_pc', inputPrompt: d.taskPrompt),
                  ))
              .toList();
          final outputs = await manager.dispatchParallelTasks(dispatches);
          for (int i = 0; i < outputs.length; i++) {
            final v = op.dispatches[i].outputVar;
            if (v != null) _registers.write(v, outputs[i].outputText);
          }
        }

      case SendMessageOp op:
        vm.messagingHub.sendMessage(AgentMessage(
          messageId: 'isa_msg_$_pc',
          senderAgentId: op.senderId,
          recipientAgentId: op.recipientId,
          payload: op.payload,
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
            : op.text;
        vm.contextManager.addRegion(ContextRegion.text(
          id: op.regionId,
          label: op.label,
          role: Role.user,
          text: content,
          priority: ContextPriority.parse(op.priority),
          lifetime: ContextLifetime.parse(op.lifetime),
          compressibility: ContextCompressibility.parse(op.compressibility),
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
        _activeToolSet = op.tools;
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

      case SetQuotaOp _:
        break; // quota enforcement handled by ResourceTracker in vm

      // ── HITL ─────────────────────────────────────────────────────────────
      case YieldHumanInteractionOp op:
      _status = _hitl.pause(request: op.request, eventBus: vm.eventBus, currentPc: _pc);

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
          _status = RuntimeStatus.halted;
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
          true || 'approved' || 'true' => true,
          false || 'rejected' || 'false' || '' || 0 || null => false,
          _ => true,
        };
        if (isTrue) _pc = op.targetPc - 1;

      case DecideOp op:
        if (op.branches.isEmpty) {
          throw StateError('DecideOp at PC $_pc has no branches.');
        }
        final outcome = await _decisionArbiter.decide(
          prompt: op.prompt,
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
            _registers.write('${op.outputVar!}_rationale', outcome.rationale);
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
        _errorHandlers.add((targetPc: op.targetPc, errorVar: op.errorVar));

      case PopErrorHandlerOp _:
        if (_errorHandlers.isNotEmpty) _errorHandlers.removeLast();

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
        _registers.jsonExtract(
          sourceVar: op.sourceVar,
          jsonKey: op.jsonKey,
          targetVar: op.targetVar,
        );

      case ConcatRegisterOp op:
        _registers.concat(targetVar: op.targetVar, sourceVars: op.sourceVars);

      case HaltOp _:
        _status = RuntimeStatus.halted;
    }
  }

  List<ToolDefinition> _activeToolSet = const [];

  /// Currently active tool definitions registered in this runtime context.
  List<ToolDefinition> get activeToolSet => List.unmodifiable(_activeToolSet);

  /// Maximum model turns in one tool-calling loop (runaway guard).
  static const int maxToolIterations = 8;

  void _checkPolicy(PolicyAction action, String resource) =>
      _policyGuard.check(action, resource);
}
