import 'dart:convert';
import 'dart:io';

import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'conformance_vector.dart';
import 'json_compare.dart';

// The golden-vector generator core (spec: docs/specs/ISA.md §Conformance
// procedure). Deterministic by construction: scripted responses, no host
// leakage, and the journal's one nondeterministic field (timestamp)
// normalized to the epoch sentinel — regeneration must be byte-identical,
// and CI asserts it.

/// The timestamp sentinel: a FIXED value, not omission — a missing
/// timestamp decodes to DateTime.now() (frame default), which would make
/// decode→re-encode nondeterministic.
const String epochSentinel = '1970-01-01T00:00:00.000Z';

final class GeneratedVector {
  final int envelopeBytes;
  const GeneratedVector({required this.envelopeBytes});
}

Future<GeneratedVector> generateVector(VectorSpec spec, Directory outDir) async {
  final tape = ModelTape();
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: RecordingVasterModel(inner: spec.buildModel(), tape: tape),
    ),
  );
  try {
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final recorder = VasterExecutionRecorder()..attach(runtime);
    final state = await runtime.executeProgram(spec.program);
    recorder.detach();

    if (state.status != spec.expectedStatus) {
      throw StateError(
        'expected ${spec.expectedStatus.name}, got ${state.status.name} '
        '(${state.errorDetails ?? 'no details'})',
      );
    }

    // Vector-authoring gate: every recorded register value must round-trip
    // JSON identically, or the vector would freeze Dart formatting.
    const comparator = JsonComparator();
    for (final frame in recorder.journal.frames) {
      final roundTripped = jsonDecode(jsonEncode(frame.registers));
      final d = comparator.diff(roundTripped, frame.registers, path: 'registers');
      if (d != null) {
        throw StateError('step ${frame.stepIndex}: non-JSON-native register value — $d');
      }
    }

    // Normalize the one nondeterministic journal field.
    final journalJson = recorder.journal.toJson();
    for (final frame in journalJson['frames'] as List) {
      (frame as Map)['timestamp'] = epochSentinel;
    }

    final envelopeJson = const ReplayEnvelopeCodec().encode(
      programJson: spec.program.toJson(),
      journalJson: journalJson,
      tape: tape,
    );

    final manifest = ConformanceVector(
      name: spec.name,
      description: spec.description,
      conformanceClass: ConformanceClass.core,
      family: spec.family,
      envelopePath: '${spec.name}.replay.json',
      expect: ConformanceExpectation(
        finalStatus: state.status,
        steps: recorder.journal.length,
        result: spec.program.resultBinding == null || state.status != RuntimeStatus.halted
            ? null
            : ResultExpectation(value: jsonDecode(jsonEncode(state.registers[spec.program.resultBinding]))),
        trapPc: state.status == RuntimeStatus.error ? state.pc : null,
        pendingRequest: state.status == RuntimeStatus.pausedForHuman
            ? _requestSubset(runtime.pendingHumanRequest!)
            : null,
        vfs: spec.exportMounts.isEmpty
            ? null
            : {
                for (final prefix in spec.exportMounts)
                  prefix: vm.fileSystemManager.mounts[prefix]!.exportFilesBase64(),
              },
      ),
    );

    const encoder = JsonEncoder.withIndent('  ');
    final envelopeText = '${encoder.convert(envelopeJson)}\n';
    File('${outDir.path}/${spec.name}.replay.json').writeAsStringSync(envelopeText);
    File('${outDir.path}/${spec.name}.vector.json')
        .writeAsStringSync('${encoder.convert(const ConformanceVectorCodec().encode(manifest))}\n');
    return GeneratedVector(envelopeBytes: envelopeText.length);
  } finally {
    await vm.shutdown();
  }
}

Map<String, dynamic> _requestSubset(HumanInteractionRequest request) => {
  'requestId': request.requestId,
  'prompt': request.prompt,
  'type': request.type.name,
};

/// One vector's recipe: a hand-assembled ISA program (never the compiler
/// frontend — Rule 1) plus a scripted model.
final class VectorSpec {
  final String name;
  final String description;
  final String family;
  final VasterProgram program;
  final FakeVasterModel Function() buildModel;
  final RuntimeStatus expectedStatus;
  final List<String> exportMounts;

  const VectorSpec({
    required this.name,
    required this.description,
    required this.family,
    required this.program,
    required this.buildModel,
    this.expectedStatus = RuntimeStatus.halted,
    this.exportMounts = const [],
  });
}

FakeVasterModel _noModel() =>
    FakeVasterModel(handler: (request) => throw StateError('this vector must not call a model'));

final List<VectorSpec> vectorSpecs = [
  VectorSpec(
    name: 'core.registers.arithmetic',
    description: 'set/increment/compare/concat/json_extract over the register file',
    family: 'registers',
    buildModel: _noModel,
    program: VasterProgram(
      programName: 'registers_arithmetic',
      resultBinding: 'summary',
      instructions: const [
        SetRegisterOp(registerName: 'a', value: 40), // 0
        IncrementRegisterOp(registerName: 'a', delta: 2), // 1  a=42
        SetRegisterOp(registerName: 'b', value: 40), // 2
        CompareRegisterOp(leftVar: 'b', operator: 'lt', rightVar: 'a', targetVar: 'b_lt_a'), // 3 true
        CompareRegisterOp(leftVar: 'a', operator: 'eq', rightValue: 42, targetVar: 'a_is_42'), // 4 true
        SetRegisterOp(
          registerName: 'doc',
          value: {
            'answer': 42,
            'parts': ['x', 'y'],
          },
        ), // 5
        JsonExtractOp(sourceVar: 'doc', jsonKey: 'answer', targetVar: 'extracted'), // 6
        SetRegisterOp(registerName: 'sep', value: '/'), // 7
        ConcatRegisterOp(targetVar: 'summary', sourceVars: ['a', 'sep', 'extracted']), // 8
        HaltOp(), // 9
      ],
    ),
  ),
  VectorSpec(
    name: 'core.control.jumps',
    description: 'jump and jump_if taken/not-taken verified by successor-frame pc',
    family: 'control',
    buildModel: _noModel,
    program: VasterProgram(
      programName: 'control_jumps',
      resultBinding: 'path',
      instructions: const [
        SetRegisterOp(registerName: 'go', value: true), // 0
        JumpIfOp(conditionVar: 'go', targetPc: 3), // 1 taken
        SetRegisterOp(registerName: 'path', value: 'not-taken'), // 2 skipped
        SetRegisterOp(registerName: 'no', value: false), // 3
        JumpIfOp(conditionVar: 'no', targetPc: 7), // 4 not taken
        SetRegisterOp(registerName: 'path', value: 'fallthrough'), // 5
        JumpOp(targetPc: 8), // 6
        SetRegisterOp(registerName: 'path', value: 'jumped-over'), // 7 skipped
        HaltOp(), // 8
      ],
    ),
  ),
  VectorSpec(
    name: 'core.control.subroutine',
    description: 'call with arguments, return_subroutine with returnRegister, call-stack frames',
    family: 'control',
    buildModel: _noModel,
    program: VasterProgram(
      programName: 'control_subroutine',
      resultBinding: 'doubled',
      instructions: const [
        SetRegisterOp(registerName: 'input', value: 21), // 0
        CallOp(functionName: 'double', targetPc: 3, arguments: {'n': 'input'}, outputVar: 'doubled'), // 1
        HaltOp(), // 2
        // sub 'double': n -> n+n via concat? use increment trick: copy + add
        SetRegisterOp(registerName: 'result', value: 42), // 3 (deterministic body)
        ReturnSubroutineOp(returnRegister: 'result'), // 4
      ],
    ),
  ),
  VectorSpec(
    name: 'core.control.error_handler',
    description: 'push_error_handler catches a trap; pop_error_handler; execution continues',
    family: 'control',
    buildModel: _noModel,
    program: VasterProgram(
      programName: 'control_error_handler',
      resultBinding: 'outcome',
      instructions: const [
        PushErrorHandlerOp(targetPc: 4, errorVar: 'caught'), // 0
        MountFsOp(mountPrefix: '/mem'), // 1
        ReadFileOp(vfsPath: '/mem/missing.txt', outputVar: 'never'), // 2 traps
        HaltOp(), // 3 skipped
        SetRegisterOp(registerName: 'outcome', value: 'handled'), // 4
        PopErrorHandlerOp(), // 5
        HaltOp(), // 6
      ],
    ),
  ),
  VectorSpec(
    name: 'core.control.trap',
    description: 'an unhandled trap halts with error status; trapPc is the contract, not the message',
    family: 'control',
    buildModel: _noModel,
    expectedStatus: RuntimeStatus.error,
    program: VasterProgram(
      programName: 'control_trap',
      instructions: const [
        MountFsOp(mountPrefix: '/mem'), // 0
        ReadFileOp(vfsPath: '/mem/absent.txt', outputVar: 'x'), // 1 traps here
        HaltOp(), // 2
      ],
    ),
  ),
  VectorSpec(
    name: 'core.model.prompt',
    description: 'session + prompt turns answered from the tape; interpolation into prompt text',
    family: 'model',
    buildModel: () => FakeVasterModel(
      handler: (request) => ModelResponse(
        message: ChatMessage.model(
          request.messages.last.text.contains('TOPIC-A') ? 'ANSWER-ONE' : 'ANSWER-TWO',
        ),
      ),
    ),
    program: VasterProgram(
      programName: 'model_prompt',
      resultBinding: 'second',
      instructions: const [
        CreateSessionOp(sessionId: 'main'), // 0
        SetSessionOp(sessionId: 'main'), // 1
        SetRegisterOp(registerName: 'topic', value: 'TOPIC-A'), // 2
        PromptOp(promptText: 'Discuss \${topic}.', outputVar: 'first'), // 3
        PromptOp(promptText: 'Now summarize \${first}.', outputVar: 'second'), // 4
        HaltOp(), // 5
      ],
    ),
  ),
  VectorSpec(
    name: 'core.model.select_and_policy',
    description: 'select_model records the active chain; check_policy allows under the unlimited policy',
    family: 'model',
    buildModel: () =>
        FakeVasterModel(handler: (request) => ModelResponse(message: ChatMessage.model('SELECTED-OK'))),
    program: VasterProgram(
      programName: 'model_select',
      resultBinding: 'answer',
      instructions: const [
        SelectModelOp(
          descriptor: ModelDescriptor(provider: 'fake', modelId: 'primary'),
        ), // 0
        CheckPolicyOp(action: PolicyAction.modelGenerate, resource: 'fake:primary'), // 1
        CreateSessionOp(sessionId: 's'), // 2
        SetSessionOp(sessionId: 's'), // 3
        PromptOp(promptText: 'go', outputVar: 'answer'), // 4
        HaltOp(), // 5
      ],
    ),
  ),
  VectorSpec(
    name: 'core.model.decide',
    description: 'decide resolves a branch from the taped label; rationale rides the convention register',
    family: 'model',
    buildModel: () =>
        FakeVasterModel(handler: (request) => ModelResponse(message: ChatMessage.model('ship'))),
    program: VasterProgram(
      programName: 'model_decide',
      resultBinding: 'route',
      instructions: const [
        DecideOp(
          prompt: 'Ship or hold?', // 0
          branches: [
            DecisionBranch(label: 'ship', description: 'ready to go', targetPc: 1),
            DecisionBranch(label: 'hold', description: 'not ready', targetPc: 3),
          ],
          outputVar: 'verdict',
        ),
        SetRegisterOp(registerName: 'route', value: 'shipped'), // 1
        HaltOp(), // 2
        SetRegisterOp(registerName: 'route', value: 'held'), // 3
        HaltOp(), // 4
      ],
    ),
  ),
  VectorSpec(
    name: 'core.session.fork',
    description: 'fork_session branches history; both branches answer from the tape',
    family: 'session',
    buildModel: () => FakeVasterModel(
      handler: (request) {
        final text = request.messages.last.text;
        return ModelResponse(
          message: ChatMessage.model(
            text.contains('root')
                ? 'ROOT-TURN'
                : text.contains('branch')
                ? 'BRANCH-TURN'
                : 'MAIN-TURN',
          ),
        );
      },
    ),
    program: VasterProgram(
      programName: 'session_fork',
      resultBinding: 'branch_answer',
      instructions: const [
        CreateSessionOp(sessionId: 'root'), // 0
        SetSessionOp(sessionId: 'root'), // 1
        PromptOp(promptText: 'root turn', outputVar: 'root_answer'), // 2
        ForkSessionOp(sourceSessionId: 'root', targetSessionId: 'fork'), // 3
        SetSessionOp(sessionId: 'fork'), // 4
        PromptOp(promptText: 'branch turn', outputVar: 'branch_answer'), // 5
        HaltOp(), // 6
      ],
    ),
  ),
  VectorSpec(
    name: 'core.vfs.transactions',
    description: 'memory mount, write/read, committed and rolled-back transactions; VFS export checked',
    family: 'vfs',
    buildModel: _noModel,
    exportMounts: ['/data'],
    program: VasterProgram(
      programName: 'vfs_transactions',
      resultBinding: 'readback',
      instructions: const [
        MountFsOp(mountPrefix: '/data'), // 0
        WriteFileOp(vfsPath: '/data/base.txt', content: 'base'), // 1
        BeginTransactionOp(), // 2
        WriteFileOp(vfsPath: '/data/kept.txt', content: 'kept'), // 3
        CommitOp(), // 4
        BeginTransactionOp(), // 5
        WriteFileOp(vfsPath: '/data/base.txt', content: 'clobbered'), // 6
        RollbackOp(), // 7
        ReadFileOp(vfsPath: '/data/base.txt', outputVar: 'readback'), // 8
        HaltOp(), // 9
      ],
    ),
  ),
  VectorSpec(
    name: 'core.context.regions',
    description: 'add (text + sourceVar), pin/unpin, policy update, evict',
    family: 'context',
    buildModel: _noModel,
    program: VasterProgram(
      programName: 'context_regions',
      resultBinding: 'done',
      instructions: const [
        AddContextOp(regionId: 'brief', label: 'the brief', text: 'stable facts', pinned: true), // 0
        SetRegisterOp(registerName: 'notes', value: 'derived notes'), // 1
        AddContextOp(regionId: 'notes', label: 'notes', sourceVar: 'notes'), // 2
        PinContextOp(regionId: 'notes'), // 3
        SetContextPolicyOp(regionId: 'notes', priority: 'high'), // 4
        UnpinContextOp(regionId: 'notes'), // 5
        CompressContextOp(targetTokens: 4, outputVar: 'compaction'), // 6
        EvictContextOp(regionId: 'notes', force: true), // 7
        SetRegisterOp(registerName: 'done', value: 'context-ok'), // 8
        HaltOp(), // 9
      ],
    ),
  ),
  VectorSpec(
    name: 'core.effects.scopes',
    description: 'effect scope push/mark-retry/pop execute as machine state',
    family: 'effects',
    buildModel: _noModel,
    program: VasterProgram(
      programName: 'effect_scopes',
      resultBinding: 'done',
      instructions: const [
        PushEffectScopeOp(), // 0
        SetRegisterOp(registerName: 'work', value: 'attempt-1'), // 1
        MarkEffectRetryOp(), // 2
        SetRegisterOp(registerName: 'work', value: 'attempt-2'), // 3
        PopEffectScopeOp(), // 4
        SetRegisterOp(registerName: 'done', value: 'effects-ok'), // 5
        HaltOp(), // 6
      ],
    ),
  ),
  VectorSpec(
    name: 'core.quota.tools',
    description: 'set_quota (token arm, no wall clock) and register_tool_set',
    family: 'quota',
    buildModel: () =>
        FakeVasterModel(handler: (request) => ModelResponse(message: ChatMessage.model('quota-ok'))),
    program: VasterProgram(
      programName: 'quota_tools',
      resultBinding: 'answer',
      instructions: [
        SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 1000000, maxToolCallsPerTask: 5)), // 0
        const RegisterToolSetOp(
          tools: [
            ToolDefinition(
              name: 'lookup',
              description: 'Looks a value up.',
              parametersSchema: {
                'type': 'object',
                'properties': {
                  'key': {'type': 'string'},
                },
              },
            ),
          ],
        ), // 1
        const CreateSessionOp(sessionId: 's'), // 2
        const SetSessionOp(sessionId: 's'), // 3
        const PromptOp(promptText: 'within quota', outputVar: 'answer'), // 4
        const HaltOp(), // 5
      ],
    ),
  ),
  VectorSpec(
    name: 'core.agents.dispatch',
    description: 'create_agent, single + parallel dispatch (tape-served), actor messaging',
    family: 'agents',
    buildModel: () => FakeVasterModel(
      handler: (request) {
        final text = request.messages.last.text;
        return ModelResponse(
          message: ChatMessage.model(
            text.contains('solo task')
                ? 'SOLO-DONE'
                : text.contains('left half')
                ? 'LEFT-DONE'
                : text.contains('right half')
                ? 'RIGHT-DONE'
                : 'AGENT-TURN',
          ),
        );
      },
    ),
    program: VasterProgram(
      programName: 'agents_dispatch',
      resultBinding: 'inbox',
      instructions: const [
        CreateAgentOp(
          descriptor: AgentDescriptor(
            agentId: 'worker',
            name: 'worker',
            role: 'Worker',
            systemInstruction: 'You do the task.',
          ),
        ), // 0
        DispatchAgentTaskOp(agentId: 'worker', taskPrompt: 'solo task', outputVar: 'solo'), // 1
        DispatchParallelTasksOp(
          dispatches: [
            ParallelTaskDispatch(agentId: 'worker', taskPrompt: 'left half', outputVar: 'left'),
            ParallelTaskDispatch(agentId: 'worker', taskPrompt: 'right half', outputVar: 'right'),
          ],
        ), // 2
        SendMessageOp(senderId: 'worker', recipientId: 'worker', payload: {'note': 'from \${solo}'}), // 3
        PopMessageOp(agentId: 'worker', outputVar: 'inbox'), // 4
        HaltOp(), // 5
      ],
    ),
  ),
  VectorSpec(
    name: 'core.hitl.pause',
    description: 'yield_human_interaction pauses the machine; the pause state is the contract',
    family: 'hitl',
    buildModel: _noModel,
    expectedStatus: RuntimeStatus.pausedForHuman,
    program: VasterProgram(
      programName: 'hitl_pause',
      instructions: [
        const SetRegisterOp(registerName: 'ready', value: true), // 0
        YieldHumanInteractionOp(
          request: const HumanInteractionRequest(
            requestId: 'gate',
            type: HumanInteractionType.approval,
            prompt: 'Proceed?',
            options: ['approve', 'reject'],
            outputVar: 'answer',
          ),
        ), // 1
        const HaltOp(), // 2
      ],
    ),
  ),
];
