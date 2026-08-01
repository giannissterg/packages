import 'dart:convert';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_vm/vaster_vm.dart';
import 'runtime_state.dart';
import 'runtime_status.dart';

/// Low-Level ISA Execution Runtime consuming [VasterVirtualMachine].
class VasterRuntime {
  final VasterVirtualMachine vm;
  final Map<String, dynamic> _registers = {};

  int _pc = 0;
  RuntimeStatus _status = RuntimeStatus.idle;
  String? _lastError;

  VasterModel? _activeModel;
  HumanInteractionRequest? _pendingHumanRequest;
  VasterProgram? _currentProgram;
  final List<Map<String, dynamic>> _callStack = [];

  VasterRuntime({required this.vm});

  /// Pending human interaction request if current status is [RuntimeStatus.pausedForHuman].
  HumanInteractionRequest? get pendingHumanRequest => _pendingHumanRequest;

  /// Current execution state.
  RuntimeState get state => RuntimeState(
        pc: _pc,
        status: _status,
        registers: Map.unmodifiable(_registers),
        errorDetails: _lastError,
      );

  /// Restores execution from raw register/PC state and resumes program execution.
  Future<RuntimeState> restoreAndResume(
    int resumePc,
    VasterProgram program, {
    Map<String, dynamic>? registers,
    HumanInteractionRequest? pendingRequest,
    HumanInteractionResponse? humanResponse,
  }) async {
    _currentProgram = program;
    _pc = resumePc;
    if (registers != null) {
      _registers.clear();
      _registers.addAll(registers);
    }
    _pendingHumanRequest = pendingRequest;

    if (humanResponse != null) {
      final req = _pendingHumanRequest;
      if (req != null && req.outputVar != null) {
        _registers[req.outputVar!] = humanResponse.value;
        _registers['${req.outputVar!}_status'] = humanResponse.status.name;
      }
      _pendingHumanRequest = null;
      _pc++; // Advance past YieldHumanInteractionOp
    }

    _status = RuntimeStatus.running;
    _lastError = null;

    return _runLoop(program);
  }

  /// Executes a [VasterProgram] step-by-step from start to finish or until [HaltOp].
  Future<RuntimeState> executeProgram(VasterProgram program) async {
    _currentProgram = program;
    _pc = 0;
    _status = RuntimeStatus.running;
    _lastError = null;
    _pendingHumanRequest = null;
    _callStack.clear();

    return _runLoop(program);
  }

  /// Resumes program execution after receiving a [HumanInteractionResponse].
  Future<RuntimeState> resumeWithHumanResponse(HumanInteractionResponse response) async {
    if (_status != RuntimeStatus.pausedForHuman || _currentProgram == null) {
      throw StateError('Runtime is not paused for human interaction.');
    }

    final req = _pendingHumanRequest;
    if (req != null && req.outputVar != null) {
      _registers[req.outputVar!] = response.value;
      _registers['${req.outputVar!}_status'] = response.status.name;
    }

    _pendingHumanRequest = null;
    _status = RuntimeStatus.running;
    _pc++; // Advance past YieldHumanInteractionOp

    return _runLoop(_currentProgram!);
  }

  Future<RuntimeState> _runLoop(VasterProgram program) async {
    while (_pc < program.instructions.length && _status == RuntimeStatus.running) {
      final instruction = program.instructions[_pc];
      try {
        await _executeInstruction(instruction);
        if (_status == RuntimeStatus.running) {
          _pc++;
        }
      } catch (e, st) {
        _status = RuntimeStatus.error;
        _lastError = '$e\n$st';
        break;
      }
    }

    if (_status == RuntimeStatus.running) {
      _status = RuntimeStatus.halted;
    }

    return state;
  }

  /// Executes a single [VasterInstruction] step.
  Future<void> _executeInstruction(VasterInstruction inst) async {
    switch (inst) {
      case PromptOp op:
        final response = await vm.prompt(op.promptText, model: _activeModel);
        if (op.outputVar != null) {
          _registers[op.outputVar!] = response.text;
        }

      case MountFsOp op:
        final fs = MemoryVasterFileSystem();
        vm.mountFileSystem(op.mountPrefix, fs);

      case WriteFileOp op:
        final targetFs = vm.fileSystemManager.resolveFileSystem(op.vfsPath);
        await targetFs.writeText(op.vfsPath, op.content);

      case ReadFileOp op:
        final targetFs = vm.fileSystemManager.resolveFileSystem(op.vfsPath);
        final content = await targetFs.readText(op.vfsPath);
        if (op.outputVar != null) {
          _registers[op.outputVar!] = content;
        }

      case RegisterSandboxOp op:
        final sandbox = IsolateCodeSandbox(
          descriptor: SandboxDescriptor(
            sandboxId: op.sandboxId,
            type: 'isolate',
            description: 'ISA Isolate Sandbox',
            supportedLanguages: [op.language],
          ),
        );
        vm.registerSandbox(sandbox);

      case ExecSandboxOp op:
        final result = await vm.sandboxManager.runCode(
          sandboxId: op.sandboxId,
          codeOrCommand: op.code,
        );
        if (op.outputVar != null) {
          _registers[op.outputVar!] = result.stdout;
        }

      case CreateAgentOp op:
        await vm.createAgent(descriptor: op.descriptor);

      case DispatchAgentTaskOp op:
        final output = await vm.runAgentTask(
          AgentTask(
            taskId: 'isa_task_$_pc',
            inputPrompt: op.taskPrompt,
          ),
          agentId: op.agentId,
        );
        if (op.outputVar != null) {
          _registers[op.outputVar!] = output.outputText;
        }

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
            final varName = op.dispatches[i].outputVar;
            if (varName != null) {
              _registers[varName] = outputs[i].outputText;
            }
          }
        }

      case SendMessageOp op:
        vm.messagingHub.sendMessage(AgentMessage(
          messageId: 'isa_msg_$_pc',
          senderAgentId: op.senderId,
          recipientAgentId: op.recipientId,
          payload: op.payload,
        ));

      case ForkSessionOp op:
        final session = vm.sessionManager.getSession(op.sourceSessionId);
        if (session != null) {
          session.fork(newSessionId: op.targetSessionId);
        }

      case PinContextOp op:
        vm.contextManager.pinRegion(op.regionId);

      case SetQuotaOp _:
        break;

      case SelectModelOp op:
        final model = vm.modelRegistry.resolveModel(op.descriptor);
        if (model != null) {
          _activeModel = model;
        }

      case YieldHumanInteractionOp op:
        _pendingHumanRequest = op.request;
        _status = RuntimeStatus.pausedForHuman;
        vm.eventBus.publish(HumanInteractionRequiredEvent(
          eventId: 'evt_hitl_$_pc',
          request: op.request,
        ));

      case CallOp op:
        for (final entry in op.arguments.entries) {
          _registers[entry.key] = entry.value;
        }
        _callStack.add({
          'functionName': op.functionName,
          'returnPc': _pc + 1,
          'outputVar': op.outputVar,
        });
        _pc = op.targetPc - 1;

      case ReturnSubroutineOp op:
        if (_callStack.isNotEmpty) {
          final topFrame = _callStack.removeLast();
          final returnPc = topFrame['returnPc'] as int;
          final outputVar = topFrame['outputVar'] as String?;

          if (op.returnRegister != null && outputVar != null) {
            _registers[outputVar] = _registers[op.returnRegister!];
          }

          _pc = returnPc - 1;
        } else {
          _status = RuntimeStatus.halted;
        }

      case JumpOp op:
        _pc = op.targetPc - 1; // -1 because _pc++ runs at end of loop

      case JumpIfOp op:
        final val = _registers[op.conditionVar];
        final isTrue = val != null && val != false && val != '' && val != 0;
        if (isTrue) {
          _pc = op.targetPc - 1;
        }

      case SetRegisterOp op:
        _registers[op.registerName] = op.value;

      case JsonExtractOp op:
        final raw = _registers[op.sourceVar];
        if (raw != null) {
          try {
            final decoded = raw is Map ? raw : jsonDecode(raw.toString());
            if (decoded is Map && decoded.containsKey(op.jsonKey)) {
              _registers[op.targetVar] = decoded[op.jsonKey];
            }
          } catch (_) {}
        }

      case ConcatRegisterOp op:
        final buffer = StringBuffer();
        for (final varName in op.sourceVars) {
          final v = _registers[varName];
          if (v != null) buffer.write(v);
        }
        _registers[op.targetVar] = buffer.toString();

      case BeginTransactionOp _:
        await vm.fileSystemManager.beginTransaction();

      case CommitOp _:
        await vm.fileSystemManager.commit();

      case RollbackOp _:
        await vm.fileSystemManager.rollback();

      case HaltOp _:
        _status = RuntimeStatus.halted;
    }
  }
}
