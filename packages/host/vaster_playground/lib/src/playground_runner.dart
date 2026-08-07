import 'dart:io';

import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'agent_responses.dart';
import 'nexus_api_pipeline.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Nexus API Pipeline Runner
//
// Compiles the multi-agent Nexus API delivery pipeline from AST to ISA
// bytecode and executes it end-to-end on the VasterRuntime.
// ══════════════════════════════════════════════════════════════════════════════

/// Runs the full Nexus API multi-agent delivery pipeline.
///
/// Pass [useGeminiCli] = `true` or specify [modelName] (e.g. `'gemini-2.5-flash'`)
/// (or provide a custom [model]) to execute the pipeline using the real local
/// Gemini CLI backend ([GeminiCliVasterModel]).
Future<void> runPlayground({VasterModel? model, bool useGeminiCli = false, String? modelName}) async {
  final isGemini = useGeminiCli || modelName != null || model is GeminiCliVasterModel;
  _printBanner(useGeminiCli: isGemini, modelName: modelName);

  // ── 1. Compile AST → ISA bytecode ─────────────────────────────────────────
  _printPhase('COMPILATION', 'Compiling Nexus API Pipeline AST → ISA bytecode');
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(nexusApiPipeline);
  _printCompilationStats(program);

  // ── 2. Select Model Backend ────────────────────────────────────────────────
  final VasterModel activeModel;
  if (model != null) {
    activeModel = model;
  } else if (useGeminiCli || modelName != null) {
    activeModel = GeminiCliVasterModel(selectedModel: modelName, extraArgs: const ['--skip-trust']);
  } else {
    activeModel = FakeVasterModel(
      defaultResponseText: 'Agent response: task completed successfully.',
      responseMap: agentResponseMap,
    );
  }

  // ── 3. Bootstrap VM ────────────────────────────────────────────────────────
  _printPhase('VM BOOTSTRAP', 'Bootstrapping VasterVMEngine with ${activeModel.modelName}');
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: activeModel, rootMountPath: '/workspace'),
  );
  final ModelDescriptor descriptor = activeModel is GeminiCliVasterModel
      ? ModelDescriptor.geminiCli(modelId: modelName ?? 'gemini-2.5-flash')
      : const ModelDescriptor.fake();

  vm.registerModel(descriptor, activeModel);

  stdout.writeln('  ✓ VM online — registered ${descriptor.descriptorKey}');
  if (activeModel is FakeVasterModel) {
    stdout.writeln('  ✓ Response map: ${agentResponseMap.length} agent personas loaded');
  } else if (activeModel is GeminiCliVasterModel) {
    final modelSpec = activeModel.selectedModel != null
        ? 'model: ${activeModel.selectedModel}'
        : 'default model';
    stdout.writeln('  ✓ Gemini CLI backend connected (${activeModel.executablePath}, $modelSpec)');
  }
  stdout.writeln();

  // ── 4. Execute program ─────────────────────────────────────────────────────
  _printPhase('EXECUTION', 'Executing ${program.instructions.length} ISA instructions');
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final stopwatch = Stopwatch()..start();
  var state = await runtime.executeProgram(program);

  // ── 5. Human-in-the-Loop & Continuation Snapshot ───────────────────────────
  if (state.status == RuntimeStatus.pausedForHuman) {
    final request = runtime.pendingHumanRequest;
    stdout.writeln('  ⏸  VM PAUSED FOR HUMAN INTERACTION (HITL)');
    stdout.writeln('     Request ID : ${request?.requestId}');
    stdout.writeln('     Prompt     : "${request?.prompt}"\n');

    _printPhase('CONTINUATION SNAPSHOT', 'Capturing VasterContinuation snapshot to JSON');
    final continuationManager = BasicContinuationManager(store: MemoryContinuationStore());
    final snapshot = await continuationManager.capture(runtime, program.programName);
    final snapshotJson = snapshot.toJson();

    stdout.writeln('  ✓ Captured VasterContinuation snapshot ID: ${snapshot.continuationId}');
    stdout.writeln('  ✓ Resume PC: ${snapshot.resumePc}');
    stdout.writeln(
      '  ✓ Machine components: '
      '${snapshot.machineState.components.keys.join(', ')}',
    );
    stdout.writeln('  ✓ JSON Payload Keys: ${snapshotJson.keys.join(', ')}\n');

    _printPhase('RESUMPTION', 'Restoring VasterContinuation & approving deployment turn');
    state = await continuationManager.restoreAndResume(
      runtime,
      snapshot,
      program,
      humanResponse: HumanInteractionResponse.approve(
        requestId: request?.requestId ?? '',
        comment: 'Approved by Playground CLI operator',
      ),
    );
  }

  stopwatch.stop();

  // ── 6. Print results ───────────────────────────────────────────────────────
  _printResults(state, stopwatch.elapsedMilliseconds);

  await vm.shutdown();
}

void _printBanner({bool useGeminiCli = false, String? modelName}) {
  final backendLabel = modelName != null
      ? 'Gemini CLI ($modelName)'
      : (useGeminiCli ? 'Gemini CLI (default)' : 'Fake Vaster Model');

  stdout.writeln('\n${'═' * 70}');
  stdout.writeln('  VASTER PLAYGROUND — Nexus API Multi-Agent Delivery Pipeline');
  stdout.writeln('  7 Agents · 7 Phases · Provider<T> · Backend: $backendLabel');
  stdout.writeln('${'═' * 70}\n');
}

void _printPhase(String label, String description) {
  stdout.writeln('┌─ $label ${'─' * (64 - label.length - 3)}┐');
  stdout.writeln('│  $description');
  stdout.writeln('└${'─' * 69}┘\n');
}

void _printCompilationStats(VasterProgram program) {
  final opcodeCounts = <String, int>{};
  for (final inst in program.instructions) {
    final op = inst.toJson()['opcode'] as String;
    opcodeCounts[op] = (opcodeCounts[op] ?? 0) + 1;
  }

  stdout.writeln('  Pipeline: ${program.programName}');
  stdout.writeln('  Total ISA instructions: ${program.instructions.length}');
  stdout.writeln('  Instruction breakdown:');
  final sorted = opcodeCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted) {
    final bar = '█' * e.value;
    stdout.writeln('    ${e.key.padRight(28)} $bar (${e.value})');
  }
  stdout.writeln();
}

void _printResults(RuntimeState state, int elapsedMs) {
  final statusIcon = state.status == RuntimeStatus.halted ? '✅' : '❌';
  stdout.writeln('$statusIcon  Execution ${state.status.name.toUpperCase()} in ${elapsedMs}ms\n');

  if (state.status != RuntimeStatus.halted) {
    stdout.writeln('  Error: ${state.errorDetails}');
    return;
  }

  // Print all produced registers
  stdout.writeln('  Produced registers (${state.registers.length}):');
  for (final entry in state.registers.entries) {
    final value = entry.value?.toString() ?? '';
    final preview = value.length > 80 ? '${value.substring(0, 77)}...' : value;
    stdout.writeln('    [${entry.key}] ${preview.replaceAll('\n', ' ')}');
  }

  // Print delivery report
  if (state.registers.containsKey('delivery_report')) {
    stdout.writeln('\n${'─' * 70}');
    stdout.writeln('  FINAL DELIVERY REPORT');
    stdout.writeln('─' * 70);
    final report = state.registers['delivery_report']?.toString() ?? '';
    for (final line in report.split('\n').take(30)) {
      stdout.writeln('  $line');
    }
  }
}
