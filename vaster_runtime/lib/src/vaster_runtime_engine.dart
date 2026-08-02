import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_vm/vaster_vm.dart';
import 'call_stack.dart';
import 'cache_hint_tracker.dart';
import 'hitl_controller.dart';
import 'register_file.dart';
import 'runtime_state.dart';
import 'runtime_status.dart';

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
/// | [VasterVirtualMachine] | All VM subsystem access (model, VFS, agents…) |
class VasterRuntime {
  final VasterVirtualMachine vm;

  final RegisterFile _registers = RegisterFile();
  final CallStack _callStack = CallStack();
  final CacheHintTracker _cacheHints = CacheHintTracker();
  final HitlController _hitl = HitlController();

  int _pc = 0;
  RuntimeStatus _status = RuntimeStatus.idle;
  String? _lastError;

  VasterModel? _activeModel;
  VasterProgram? _currentProgram;

  VasterRuntime({required this.vm});

  /// Pending human interaction request if status is [RuntimeStatus.pausedForHuman].
  HumanInteractionRequest? get pendingHumanRequest => _hitl.pendingRequest;

  /// Current execution state snapshot.
  RuntimeState get state => RuntimeState(
        pc: _pc,
        status: _status,
        registers: _registers.snapshot(),
        errorDetails: _lastError,
      );

  /// Executes a [VasterProgram] from the beginning until [HaltOp] or error.
  Future<RuntimeState> executeProgram(VasterProgram program) async {
    _currentProgram = program;
    _pc = 0;
    _status = RuntimeStatus.running;
    _lastError = null;
    _registers.clear();
    _callStack.clear();
    _cacheHints.clear();
    _hitl.clear();

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
  Future<RuntimeState> restoreAndResume(
    int resumePc,
    VasterProgram program, {
    Map<String, dynamic>? registers,
    HumanInteractionRequest? pendingRequest,
    HumanInteractionResponse? humanResponse,
  }) async {
    _currentProgram = program;
    _pc = resumePc;
    if (registers != null) _registers.restore(registers);
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

  Future<RuntimeState> _runLoop(VasterProgram program) async {
    while (_pc < program.instructions.length && _status == RuntimeStatus.running) {
      final instruction = program.instructions[_pc];
      try {
        await _executeInstruction(instruction);
        if (_status == RuntimeStatus.running) _pc++;
      } catch (e, st) {
        _status = RuntimeStatus.error;
        _lastError = '$e\n$st';
        break;
      }
    }
    if (_status == RuntimeStatus.running) _status = RuntimeStatus.halted;
    return state;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispatch table — each arm delegates to the correct owner (≤3 lines each)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _executeInstruction(VasterInstruction inst) async {
    switch (inst) {
      // ── Model / LLM ───────────────────────────────────────────────────────
      case PromptOp op:
        final response = await vm.prompt(
          op.promptText,
          model: _activeModel,
          cacheHints: _cacheHints.activeHints,
        );
        if (op.outputVar != null) _registers.write(op.outputVar!, response.text);

      case SelectModelOp op:
        _activeModel = vm.modelRegistry.resolveModel(op.descriptor);

      // ── Filesystem ────────────────────────────────────────────────────────
      case MountFsOp op:
        vm.mountFileSystem(op.mountPrefix, MemoryVasterFileSystem());

      case WriteFileOp op:
        final fs = vm.fileSystemManager.resolveFileSystem(op.vfsPath);
        await fs.writeText(op.vfsPath, op.content);

      case ReadFileOp op:
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
        final result = await vm.sandboxManager.runCode(
          sandboxId: op.sandboxId,
          codeOrCommand: op.code,
        );
        if (op.outputVar != null) _registers.write(op.outputVar!, result.stdout);

      // ── Agents ────────────────────────────────────────────────────────────
      case CreateAgentOp op:
        await vm.createAgent(descriptor: op.descriptor);

      case DispatchAgentTaskOp op:
        final meta = _cacheHints.isEmpty
            ? <String, dynamic>{}
            : {'cacheHints': _cacheHints.activeHints.map((h) => h.toJson()).toList()};
        final output = await vm.runAgentTask(
          AgentTask(taskId: 'isa_task_$_pc', inputPrompt: op.taskPrompt, metadata: meta),
          agentId: op.agentId,
        );
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

      // ── Session / Context ─────────────────────────────────────────────────
      case ForkSessionOp op:
        vm.sessionManager.getSession(op.sourceSessionId)?.fork(newSessionId: op.targetSessionId);

      case PinContextOp op:
        vm.contextManager.pinRegion(op.regionId);
        _cacheHints.onRegionPinned(op.regionId, vm.contextManager);

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
        final isTrue = val != null && val != false && val != '' && val != 0;
        if (isTrue) _pc = op.targetPc - 1;

      // ── Register file ─────────────────────────────────────────────────────
      case SetRegisterOp op:
        _registers.write(op.registerName, op.value);

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
}
