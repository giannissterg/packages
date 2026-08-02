import 'dart:convert';

import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm/vaster_vm.dart';
import 'call_stack.dart';
import 'cache_hint_tracker.dart';
import 'hitl_controller.dart';
import 'register_file.dart';
import 'runtime_state.dart';
import 'runtime_status.dart';

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
      } catch (e, st) {
        _status = RuntimeStatus.error;
        _lastError = _formatTrap(instruction, e, st);
        break;
      }
    }
    if (_status == RuntimeStatus.running) _status = RuntimeStatus.halted;
    return state;
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

  /// Executes up to [stepCount] instructions of [program] and returns the resulting [RuntimeState].
  Future<RuntimeState> executeStep(VasterProgram program, {int stepCount = 5}) async {
    if (_status == RuntimeStatus.idle) {
      _status = RuntimeStatus.running;
    }
    int executed = 0;
    while (_pc < program.instructions.length &&
        _status == RuntimeStatus.running &&
        executed < stepCount) {
      if (budget.isExpired) {
        _status = RuntimeStatus.timedOut;
        _lastError = 'Execution budget or deadline expired at PC $_pc';
        break;
      }
      final instruction = program.instructions[_pc];
      // Capture the executing PC before dispatch (control-flow ops mutate _pc).
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
        _status = RuntimeStatus.error;
        _lastError = _formatTrap(instruction, e, st);
        break;
      }
    }
    if (_pc >= program.instructions.length && _status == RuntimeStatus.running) {
      _status = RuntimeStatus.halted;
    }
    return state;
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
          response = await _executeToolCallingLoop(
            prompt: op.promptText,
            initialResponse: response,
            sessionId: _activeSessionId,
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
        final result = await vm.sandboxManager.runCode(
          sandboxId: op.sandboxId,
          codeOrCommand: op.code,
        );
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

  List<ToolDefinition> _activeToolSet = const [];

  /// Currently active tool definitions registered in this runtime context.
  List<ToolDefinition> get activeToolSet => List.unmodifiable(_activeToolSet);

  /// Maximum model turns in one tool-calling loop (runaway guard).
  static const int maxToolIterations = 8;

  /// The ABI-preserving tool-calling loop.
  ///
  /// Tool calls dispatch through the VM's [ToolManager] symbol table — any
  /// registered tool (sandbox bridges, function tools, toolsets) is callable
  /// by the model. `write_file` / `read_file` remain as built-in VFS syscalls
  /// when no registered tool overrides them. Every result returns to the model
  /// as a typed `tool_result` part in a full transcript continuation — never
  /// flattened to prose.
  Future<ModelResponse> _executeToolCallingLoop({
    required String prompt,
    required ModelResponse initialResponse,
    String? sessionId,
  }) async {
    var response = initialResponse;
    final transcript = <ChatMessage>[ChatMessage.user(prompt)];

    // Linked symbol table: program-registered defs + VM tool registry.
    final toolDefinitions = {
      for (final def in vm.toolManager.compiledDefinitions) def.name: def,
      for (final def in _activeToolSet) def.name: def,
    }.values.toList();

    var iterations = 0;
    while (response.functionCalls.isNotEmpty && iterations < maxToolIterations) {
      iterations++;

      // Echo the assistant turn (with its tool_use parts), then execute every
      // call in the turn and answer them all in a single tool message.
      transcript.add(response.message);
      final results = <ContentPart>[];
      for (final call in response.functionCalls) {
        _checkPolicy(PolicyAction.toolCall, call.name);
        results.add(FunctionResponsePart(
          callId: call.callId,
          name: call.name,
          response: await _dispatchToolCall(call),
        ));
      }
      transcript.add(ChatMessage(role: Role.tool, parts: results));

      response = await vm.promptWithHistory(
        transcript,
        model: _activeModel,
        tools: toolDefinitions,
        cacheHints: _cacheHints.activeHints,
      );
      budget.consumeTokens(response.usage.totalTokenCount > 0
          ? response.usage.totalTokenCount
          : response.text.length ~/ 4);
    }
    return response;
  }

  /// Dispatches one tool call. Built-in VFS syscalls take precedence — they
  /// carry the runtime's policy checks (fileWrite/fileRead), which registered
  /// handlers cannot enforce. Everything else resolves through the VM's
  /// [ToolManager] symbol table; unlinked names return a typed error payload
  /// the model can recover from.
  Future<Map<String, dynamic>> _dispatchToolCall(FunctionCallPart call) async {
    try {
      // 1. Built-in policy-gated VFS syscalls (must win over registrations so
      //    the ExecutionPolicy cannot be bypassed via the tool table).
      switch (call.name) {
        case 'write_file':
          final path = call.arguments['path']?.toString() ?? '';
          _checkPolicy(PolicyAction.fileWrite, path);
          final content = call.arguments['content']?.toString() ?? '';
          await vm.fileSystemManager.resolveFileSystem(path).writeText(path, content);
          return {'status': 'ok', 'path': path};
        case 'read_file':
          final path = call.arguments['path']?.toString() ?? '';
          _checkPolicy(PolicyAction.fileRead, path);
          final content =
              await vm.fileSystemManager.resolveFileSystem(path).readText(path);
          return {'content': content};
      }

      // 2. Symbol table — the linked tool registry.
      if (vm.toolManager.getTool(call.name) != null) {
        final result = await vm.toolManager.executeCall(call);
        return result.isError
            ? {'error': result.errorDetails ?? 'Tool execution failed.'}
            : result.response;
      }

      // 3. Unlinked symbol.
      return {
        'error':
            'Unknown tool "${call.name}" — not registered in the VM tool table.',
      };
    } on StateError catch (e) {
      if (e.message.startsWith('Policy violation')) rethrow; // security trap
      return {'error': e.message};
    } catch (e) {
      return {'error': 'Tool execution error: $e'};
    }
  }

  void _checkPolicy(PolicyAction action, String resource) {
    final decision = vm.policyEngine.authorize(
      policy: _activePolicy,
      action: action,
      resource: resource,
    );
    if (decision.isDenied) {
      throw StateError('Policy violation: ${decision.reason}');
    }
  }
}
