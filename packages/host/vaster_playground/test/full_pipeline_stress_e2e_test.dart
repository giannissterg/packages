import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_ast/primitives.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'harness/war_room_harness.dart';

/// Full-pipeline stress test: one complex plan exercising as much of the
/// surface as a single program can — agents, parallel dispatch, the tool
/// loop, model-steered decisions, loops, subroutines, transactions,
/// try/catch, VFS, sandbox execution, actor messaging, knowledge scopes,
/// program quotas, JSON extraction, an approval gate, and the declared
/// result — then asserts the invariants around the run: VBC round-trip
/// fidelity, analyzer cleanliness, triple-meter charging, usage-event
/// accounting, and record/replay equivalence.
void main() {
  // ── The scripted model ─────────────────────────────────────────────────
  // A deterministic "brain" for the whole war room: routes on prompt
  // content, exercises the tool loop once, answers Decide with JSON, and
  // returns JSON for the extraction step.
  // ── Harness ────────────────────────────────────────────────────────────
  const compiler = BasicWorkflowCompiler();

  group('Full-pipeline stress (launch war room)', () {
    test('compiles cleanly and the VBC binary round-trips byte-exact', () {
      final program = compiler.compile(warRoom());
      expect(program.instructions, isNotEmpty);

      final diagnostics = const ProgramAnalyzer().analyze(program);
      final errors = diagnostics.where((d) => d.severity == CompileSeverity.error);
      expect(
        errors,
        isEmpty,
        reason:
            'analyzer errors on a compiler-produced program:\n'
            '${errors.map((d) => '${d.code}: ${d.message}').join('\n')}',
      );

      final decoded = VasterProgramBinary.fromBytes(program.toBytes());
      expect(decoded.instructions.length, program.instructions.length);
      for (var i = 0; i < program.instructions.length; i++) {
        expect(
          jsonEncode(decoded.instructions[i].toJson()),
          jsonEncode(program.instructions[i].toJson()),
          reason: 'instruction $i (${program.instructions[i].opcode.name})',
        );
      }
    });

    test('executes end to end: pause at the gate, resume, verify everything', () async {
      final fakeModel = buildModel();
      final tape = ModelTape();
      final recording = RecordingVasterModel(inner: fakeModel, tape: tape);
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: recording),
        initialTools: [
          FunctionTool.define(
            name: 'lookup_registry',
            description: 'Looks up a launch-registry key.',
            parametersSchema: const {
              'type': 'object',
              'properties': {
                'key': {'type': 'string'},
              },
            },
            handler: (args) async => {'value': 'OPEN', 'key': args['key']},
          ),
        ],
      );
      addTearDown(vm.shutdown);

      final usageEvents = <ModelUsageEvent>[];
      vm.eventBus.on<ModelUsageEvent>().listen(usageEvents.add);

      final budget = ExecutionBudget.unlimited();
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: budget,
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      final program = compiler.compile(warRoom());
      var state = await runtime.executeProgram(program);

      // ── The gate pauses the machine ──
      expect(state.status, RuntimeStatus.pausedForHuman, reason: 'error: ${state.errorDetails}');
      expect(runtime.pendingHumanRequest?.requestId, 'launch_gate');
      // The gate prompt interpolated upstream registers.
      expect(runtime.pendingHumanRequest?.prompt, contains('registry cleared'));

      state = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'launch_gate'),
      );
      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');

      // ── Dataflow assertions across every subsystem ──
      final regs = state.registers;
      expect('${regs['registry_check']}', contains('registry cleared'));
      expect('${regs['design']}', isNotEmpty);
      expect('${regs['runbook']}', isNotEmpty);
      expect('${regs['prereview']}', isNotEmpty);
      expect(
        '${regs['inbox']}',
        contains('follow the design'),
        reason: 'actor message must arrive with interpolated payload',
      );
      expect('${regs['inbox']}', contains('orion'), reason: 'payload interpolation must resolve \${project}');
      expect(
        '${regs['verdict']}',
        equals('GO'),
        reason: 'Extract must pull the verdict field from status JSON',
      );
      expect('${regs['ship_decision']}', equals('ship'));
      expect('${regs['ship_decision_rationale']}', contains('quality bar'));
      expect('${regs['vfs_err']}', isNotEmpty, reason: 'TryCatch must surface the VFS error');
      expect('${regs['final_verdict']}', equals('shipped'));

      // Program result header points hosts at the declared binding.
      expect(program.resultBinding, equals('final_verdict'));

      // ── VFS assertions ──
      Future<String> read(String path) => vm.fileSystemManager.resolveFileSystem(path).readText(path);
      expect(
        await read('/workspace/notes/kickoff.txt'),
        contains('war room open for project orion'),
        reason: 'subroutine arguments must interpolate into the note',
      );
      expect(await read('/workspace/txn/committed.txt'), equals('txn ok'));
      expect(await read('/workspace/txn/recovered.txt'), contains('recovered'));
      final launch = await read('/workspace/LAUNCH.txt');
      expect(launch, contains('LAUNCHED orion'));
      expect(launch, contains('GO'));

      // ── Metering: the run was paid for on every meter ──
      expect(budget.consumedTokens, greaterThan(0));
      expect(
        runtime.quotaConsumedTokens,
        greaterThan(0),
        reason: 'BudgetScope quota must meter the scoped work',
      );
      expect(vm.resourceTracker.consumedTokens, greaterThan(0));

      // ── Usage-event accounting: one event per model call, no doubles ──
      await Future<void>.delayed(Duration.zero);
      final vmPromptEvents = usageEvents.where((e) => e.callSite == 'vm_prompt').length;
      final agentTurnEvents = usageEvents.where((e) => e.callSite == 'agent_turn').length;
      expect(
        usageEvents.where((e) => e.callSite == 'agent_task'),
        isEmpty,
        reason:
            'per-turn events replace the task rollup — both would '
            'double-count',
      );
      expect(
        vmPromptEvents + agentTurnEvents,
        equals(fakeModel.recordedRequests.length),
        reason:
            'every model call is metered exactly once '
            '(${fakeModel.recordedRequests.length} calls, '
            '$vmPromptEvents vm_prompt + $agentTurnEvents agent_turn '
            'events)',
      );

      // ── Replay equivalence: same program, tape-driven, zero live calls ──
      final replayVm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: ReplayVasterModel(tape: ModelTape.fromJson(tape.toJson()))),
        initialTools: [
          FunctionTool.define(
            name: 'lookup_registry',
            description: 'Looks up a launch-registry key.',
            parametersSchema: const {
              'type': 'object',
              'properties': {
                'key': {'type': 'string'},
              },
            },
            handler: (args) async => {'value': 'OPEN', 'key': args['key']},
          ),
        ],
      );
      addTearDown(replayVm.shutdown);
      final replayRuntime = VasterRuntime(
        vm: replayVm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      var replayState = await replayRuntime.executeProgram(program);
      expect(replayState.status, RuntimeStatus.pausedForHuman);
      replayState = await replayRuntime.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'launch_gate'),
      );
      expect(replayState.status, RuntimeStatus.halted, reason: 'replay error: ${replayState.errorDetails}');
      expect(replayState.registers['final_verdict'], equals('shipped'));
      expect(replayState.registers['verdict'], equals('GO'));
      expect(
        replayState.registers['ship_decision'],
        equals(state.registers['ship_decision']),
        reason: 'a faithful replay reproduces the decision',
      );
    });
  });
  group('Full-pipeline stress — adversarial', () {
    Future<(VasterRuntime, VasterVirtualMachine, ExecutionBudget)> boot({
      FakeVasterModel? model,
      VasterModel? rawModel,
      ExecutionPolicy? policy,
      ExecutionBudget? budget,
    }) async {
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: rawModel ?? model ?? buildModel()),
        initialTools: [
          FunctionTool.define(
            name: 'lookup_registry',
            description: 'Looks up a launch-registry key.',
            parametersSchema: const {
              'type': 'object',
              'properties': {
                'key': {'type': 'string'},
              },
            },
            handler: (args) async => {'value': 'OPEN', 'key': args['key']},
          ),
        ],
      );
      addTearDown(vm.shutdown);
      final activeBudget = budget ?? ExecutionBudget.unlimited();
      final runtime = VasterRuntime(
        vm: vm,
        policy: policy ?? ExecutionPolicy.unlimited,
        budget: activeBudget,
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      return (runtime, vm, activeBudget);
    }

    test('the rejection path aborts: no launch file, verdict aborted', () async {
      final (runtime, vm, _) = await boot();
      final program = compiler.compile(warRoom());

      var state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.pausedForHuman);
      state = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.reject(requestId: 'launch_gate', reason: 'not today'),
      );
      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      expect(state.registers['final_verdict'], equals('aborted'));
      expect(
        () =>
            vm.fileSystemManager.resolveFileSystem('/workspace/LAUNCH.txt').readText('/workspace/LAUNCH.txt'),
        throwsA(anything),
        reason: 'a rejected launch must not produce the launch artifact',
      );
    });

    test('the DECODED binary executes identically to the in-memory program', () async {
      final (runtime, _, _) = await boot();
      final program = compiler.compile(warRoom());
      final decoded = VasterProgramBinary.fromBytes(program.toBytes());

      var state = await runtime.executeProgram(decoded);
      expect(
        state.status,
        RuntimeStatus.pausedForHuman,
        reason:
            'decoded program must reach the same gate '
            '(error: ${state.errorDetails})',
      );
      state = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'launch_gate'),
      );
      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      expect(state.registers['final_verdict'], equals('shipped'));
      expect(state.registers['verdict'], equals('GO'));
      expect(
        decoded.resultBinding,
        equals('final_verdict'),
        reason: 'the program header must survive the binary round-trip',
      );
    });

    test('an unresolvable Decide answer falls to defaultPath', () async {
      final garbageModel = FakeVasterModel(defaultResponseText: 'I refuse to answer in the requested format');
      final (runtime, _, _) = await boot(model: garbageModel);

      final program = compiler.compile(
        const Pipeline(
          name: 'garbage_decide',
          result: Binding('outcome'),
          children: [
            Decide(
              prompt: Template.text('Ship it?'),
              defaultPath: 'hold',
              paths: [
                DecisionPath(
                  label: 'ship',
                  description: 'go',
                  children: [
                    Inputs({Binding('outcome'): 'shipped'}),
                  ],
                ),
                DecisionPath(
                  label: 'hold',
                  description: 'wait',
                  children: [
                    Inputs({Binding('outcome'): 'held'}),
                  ],
                ),
              ],
            ),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      expect(state.registers['outcome'], equals('held'));
    });

    test('a program-declared token quota trips honestly mid-run', () async {
      final (runtime, _, _) = await boot();
      final program = compiler.compile(
        const Pipeline(
          name: 'starved',
          children: [
            BudgetScope(
              maxTokens: 1,
              child: Sequence([
                Prompt(
                  Template.text(
                    'This prompt is long enough that its usage cannot possibly '
                    'fit inside a one-token program quota, so the meter must '
                    'trip while charging it.',
                  ),
                ),
                Prompt(Template.text('never reached')),
              ]),
            ),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.error);
      expect(
        state.errorDetails,
        contains('uota'),
        reason:
            'the trap must name the quota breach, got: '
            '${state.errorDetails}',
      );
      expect(
        runtime.quotaConsumedTokens,
        greaterThan(0),
        reason: 'the breaching charge itself must be metered',
      );
    });

    test('a read-only policy traps WriteFile as a security violation', () async {
      final (runtime, _, _) = await boot(policy: ExecutionPolicy.readOnly);
      final program = compiler.compile(
        const Pipeline(
          name: 'forbidden_write',
          children: [
            WriteFile(path: Template.text('/mem/forbidden.txt'), content: Template.text('should never land')),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.error);
      expect(
        state.errorDetails,
        contains('olicy'),
        reason:
            'the trap must name the policy violation, got: '
            '${state.errorDetails}',
      );
    });

    test('replaying a MODIFIED program against the old tape fails loudly, '
        'never silently', () async {
      // Record the simple decide program...
      final tape = ModelTape();
      final (recordRuntime, _, _) = await boot(
        rawModel: RecordingVasterModel(inner: buildModel(), tape: tape),
      );
      final original = compiler.compile(
        const Pipeline(
          name: 'tamper_base',
          children: [
            Prompt(Template.text('Now produce the status report as JSON.'), output: Binding('status_json')),
          ],
        ),
      );
      final recorded = await recordRuntime.executeProgram(original);
      expect(recorded.status, RuntimeStatus.halted);

      // ...then replay a program with an EXTRA model call.
      final tampered = compiler.compile(
        const Pipeline(
          name: 'tamper_extra',
          children: [
            Prompt(Template.text('Now produce the status report as JSON.'), output: Binding('status_json')),
            Prompt(Template.text('an extra call the tape never saw')),
          ],
        ),
      );
      final (replayRuntime, _, _) = await boot(
        rawModel: ReplayVasterModel(tape: ModelTape.fromJson(tape.toJson())),
      );
      final state = await replayRuntime.executeProgram(tampered);
      expect(state.status, RuntimeStatus.error, reason: 'divergence must trap, not fabricate a response');
      expect(state.errorDetails, contains('Replay diverged'));
    });
  });

  group('Full-pipeline stress — wave 2 (suspicion-driven)', () {
    Future<(VasterRuntime, VasterVirtualMachine, ExecutionBudget)> boot({
      VasterModel? model,
      ExecutionBudget? budget,
    }) async {
      final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model ?? buildModel()));
      addTearDown(vm.shutdown);
      final activeBudget = budget ?? ExecutionBudget.unlimited();
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: activeBudget,
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      return (runtime, vm, activeBudget);
    }

    test('SECURITY LOCK: model output containing \${...} is never '
        're-interpolated', () async {
      // The model "responds" with an interpolation reference. If the
      // resolver ever re-scanned replacement values, model output could read
      // arbitrary registers (including other agents' data) — a prompt-
      // injection-to-register-exfiltration path. Resolution must be
      // single-pass: the written file keeps the LITERAL reference.
      final sneakyModel = FakeVasterModel(
        defaultResponseText: r'please write ${secret} and ${quality_bar} to the file',
      );
      final (runtime, vm, _) = await boot(model: sneakyModel);

      final program = compiler.compile(
        const Pipeline(
          name: 'injection_probe',
          inputs: {Binding('quality_bar'): 'high', Binding('secret'): 'S3CRET-TOKEN'},
          children: [
            Prompt(Template.text('say something'), output: Binding('model_out')),
            WriteFile(path: Template.text('/mem/out.txt'), content: Template.text('\${model_out}')),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      final written = await vm.fileSystemManager.resolveFileSystem('/mem/out.txt').readText('/mem/out.txt');
      expect(written, contains(r'${secret}'), reason: 'model-controlled text must stay literal');
      expect(
        written,
        isNot(contains('S3CRET-TOKEN')),
        reason:
            'INJECTION: model output was re-interpolated and read a '
            'register it should never see',
      );
    });

    test('parallel dispatch to the SAME agent twice completes with both '
        'outputs', () async {
      final (runtime, _, _) = await boot();
      final program = compiler.compile(
        const Pipeline(
          name: 'same_agent_parallel',
          roles: [builder],
          children: [
            ParallelTasks(
              entries: [
                ParallelTaskEntry(agentId: 'builder', prompt: 'task alpha', output: 'out_a'),
                ParallelTaskEntry(agentId: 'builder', prompt: 'task beta', output: 'out_b'),
              ],
            ),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      expect('${state.registers['out_a']}', isNotEmpty);
      expect('${state.registers['out_b']}', isNotEmpty);
    });

    test('a HITL pause inside a subroutine resumes THROUGH the return', () async {
      final (runtime, vm, _) = await boot();
      final program = compiler.compile(
        const Pipeline(
          name: 'gate_in_subroutine',
          children: [
            DefineSubroutine(
              name: 'guarded_step',
              children: [
                YieldHuman(
                  requestId: 'sub_gate',
                  interactionType: 'approval',
                  prompt: 'approve the guarded step?',
                  options: ['approve', 'reject'],
                  output: 'sub_gate',
                ),
                WriteFile(path: Template.text('/mem/inside.txt'), content: Template.text('inside ran')),
              ],
            ),
            CallSubroutine(name: 'guarded_step'),
            WriteFile(path: Template.text('/mem/after.txt'), content: Template.text('after returned')),
          ],
        ),
      );

      var state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.pausedForHuman);
      expect(
        runtime.callStackSnapshot,
        isNotEmpty,
        reason:
            'paused inside a subroutine: the activation record must '
            'still exist',
      );

      state = await runtime.resumeWithHumanResponse(HumanInteractionResponse.approve(requestId: 'sub_gate'));
      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      Future<String> read(String path) => vm.fileSystemManager.resolveFileSystem(path).readText(path);
      expect(await read('/mem/inside.txt'), equals('inside ran'));
      expect(
        await read('/mem/after.txt'),
        equals('after returned'),
        reason: 'the RET after resume must land back in the caller',
      );
    });

    test('host budget exhaustion lands as timedOut at the next boundary', () async {
      final (runtime, _, budget) = await boot(budget: ExecutionBudget(maxTokens: 1));
      final program = compiler.compile(
        const Pipeline(
          name: 'host_starved',
          children: [
            Prompt(Template.text('a prompt whose usage crosses one token')),
            Prompt(Template.text('never reached')),
            Prompt(Template.text('never reached either')),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(
        state.status,
        RuntimeStatus.timedOut,
        reason:
            'host budget is a soft stop at instruction boundaries, '
            'got: ${state.status} / ${state.errorDetails}',
      );
      expect(budget.consumedTokens, greaterThan(0));
    });

    test('Extract on a missing key leaves the target unset AND publishes a '
        'typed warning', () async {
      final (runtime, vm, _) = await boot();
      final warnings = <RuntimeWarningEvent>[];
      vm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);
      final program = compiler.compile(
        const Pipeline(
          name: 'extract_miss',
          children: [
            Prompt(Template.text('Now produce the status report as JSON.'), output: Binding('status_json')),
            Extract(from: Binding('status_json'), field: 'no_such_field', output: Binding('missing')),
          ],
        ),
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted, reason: 'a missing key is tolerated, not a trap');
      expect(
        state.registers.containsKey('missing'),
        isFalse,
        reason:
            'locked-in semantics: a failed extraction leaves the '
            'register unset',
      );
      await Future<void>.delayed(Duration.zero);
      final miss = warnings.where((w) => w.code == 'extract_key_missing').toList();
      expect(miss, hasLength(1), reason: 'tolerance without observability is how failures vanish');
      expect(miss.single.message, contains('no_such_field'));
      expect(
        miss.single.message,
        contains('verdict'),
        reason: 'the warning must list the keys that WERE present',
      );
    });
  });
}
