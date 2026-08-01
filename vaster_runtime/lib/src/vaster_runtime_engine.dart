import 'dart:async';
import 'dart:convert';
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

  VasterRuntime({required this.vm});

  /// Current execution state.
  RuntimeState get state => RuntimeState(
        pc: _pc,
        status: _status,
        registers: Map.unmodifiable(_registers),
        errorDetails: _lastError,
      );

  /// Executes a [VasterProgram] step-by-step from start to finish or until [HaltOp].
  Future<RuntimeState> executeProgram(VasterProgram program) async {
    _pc = 0;
    _status = RuntimeStatus.running;
    _lastError = null;

    while (_pc < program.instructions.length && _status == RuntimeStatus.running) {
      final instruction = program.instructions[_pc];
      try {
        await _executeInstruction(instruction);
        _pc++;
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
        final response = await vm.prompt(op.promptText);
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
