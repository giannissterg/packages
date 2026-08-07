import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Dogfood: point the framework at ANOTHER codebase and have it produce a
/// reviewed development plan, written INTO that codebase.
///
/// The pipeline disk-mounts the target project at `/project`, reads its
/// real files into bindings, and runs the SDD kit (Specify → Plan →
/// Review) grounded in that content. Artifacts land in
/// `<target>/planning/` as ordinary files; the whole run can be recorded
/// to a replay envelope for `vaster debug` / `--resume-at`.
///
///     dart run vaster_playground:plan_external_codebase <targetDir> \
///         [--backend fake|claude-cli] [--record out.replay.json]
void main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('Usage: plan_external_codebase <targetDir> '
        '[--backend fake|claude-cli] [--record out.replay.json]');
    exitCode = 1;
    return;
  }
  final targetDir = Directory(positional.first).absolute.path;
  if (!Directory(targetDir).existsSync()) {
    stderr.writeln('Error: target directory not found: $targetDir');
    exitCode = 1;
    return;
  }
  String? argOf(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final backendName = argOf('backend') ?? 'fake';
  final recordPath = argOf('record');

  // ── The pipeline: three roles plan someone else's codebase ──
  const architect = AgentRole(
    roleId: 'architect',
    name: 'Product Architect',
    title: 'Flutter Product Architect',
    instruction: 'You write precise, reviewable product specifications for Flutter apps. '
        'You ground every claim in the actual code you are shown — never invent files.',
  );
  const lead = AgentRole(
    roleId: 'lead',
    name: 'Tech Lead',
    title: 'Flutter Tech Lead',
    instruction: 'You turn specifications into concrete, ordered implementation plans: '
        'exact files to create or modify, package choices with rationale, and a test strategy.',
  );
  const reviewer = AgentRole(
    roleId: 'reviewer',
    name: 'Reviewer',
    title: 'Staff Engineer',
    instruction: 'You review plans rigorously: feasibility, ordering, missing work, '
        'testability. You call out anything not grounded in the real codebase.',
  );

  final pipeline = Pipeline(
    name: 'external_codebase_plan',
    result: const Binding('review'),
    roles: const [architect, lead, reviewer],
    mounts: [StorageMount(mountPrefix: '/project', type: StorageMountType.disk, diskPath: targetDir)],
    children: [
      const Provider<SddConventions>(
        value: SddConventions(root: '/project/planning'),
        children: [
          // Ground the pipeline in the REAL codebase: these are actual
          // file reads through the disk mount, not pasted context.
          ReadFile(path: Template.text('/project/pubspec.yaml'), output: Binding('pubspec')),
          ReadFile(path: Template.text('/project/lib/main.dart'), output: Binding('main_dart')),
          Specify(
            agent: architect,
            goal: 'Turn this freshly generated Flutter starter into "Pocket Tasks" — '
                'a small offline-first personal task manager: task list with '
                'add/edit/complete/delete, local persistence that survives restarts, '
                'light/dark theming, and meaningful widget tests. Scope it as ONE '
                'incremental milestone an individual developer ships in a week.\n\n'
                'The ACTUAL current codebase you are planning against:\n\n'
                '--- pubspec.yaml ---\n\${pubspec}\n\n'
                '--- lib/main.dart ---\n\${main_dart}',
          ),
          Plan(agent: lead),
          Review(agent: reviewer),
        ],
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  print('compiled ${program.instructions.length} instructions '
      '(result binding: ${program.resultBinding})');

  // ── Backend ──
  final VasterModel backend = switch (backendName) {
    'claude-cli' => ClaudeCliVasterModel(selectedModel: 'sonnet'),
    'fake' => FakeVasterModel(
      handler: (request) {
        final prompt = request.messages.last.text;
        // Order matters: the review prompt embeds the plan it reviews, so
        // sniff the most specific phase first.
        final text = prompt.contains('Review')
            ? '# Review\n\nAPPROVE — (fake review)'
            : prompt.contains('specification')
            ? '# Pocket Tasks — Specification\n\n(fake spec grounded in '
                  '${prompt.contains('flutter') ? 'the real pubspec' : 'the prompt'})'
            : '# Implementation Plan\n\n1. (fake step)';
        return ModelResponse(message: ChatMessage.model(text));
      },
    ),
    _ => throw ArgumentError('unknown backend "$backendName" (fake|claude-cli)'),
  };

  final tape = ModelTape();
  final model = recordPath != null ? RecordingVasterModel(inner: backend, tape: tape) : backend;

  final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );
  final recorder = recordPath != null ? (VasterExecutionRecorder()..attach(runtime)) : null;

  print('planning $targetDir on $backendName…\n');
  final state = await runtime.executeProgram(program);
  recorder?.detach();

  if (recordPath != null) {
    File(recordPath).writeAsStringSync(
      jsonEncode(
        const ReplayEnvelopeCodec().encode(
          programJson: program.toJson(),
          journalJson: recorder!.journal.toJson(),
          tape: tape,
        ),
      ),
    );
  }

  print('status  : ${state.status.name}');
  if (state.status == RuntimeStatus.error) {
    stderr.writeln(state.errorDetails);
    await vm.shutdown();
    exitCode = 1;
    return;
  }
  print('tokens  : ${runtime.budget.consumedTokens}'
      '${runtime.budget.consumedCost > 0 ? ' · cost \$${runtime.budget.consumedCost.toStringAsFixed(4)}' : ''}');
  final planningDir = Directory('$targetDir/planning');
  if (planningDir.existsSync()) {
    print('artifacts:');
    for (final f in planningDir.listSync().whereType<File>()) {
      print('  ${f.path}  (${f.lengthSync()} bytes)');
    }
  }
  if (recordPath != null) print('envelope: $recordPath');
  print('\nreview verdict (pipeline result):\n${state.registers[program.resultBinding]}');

  await vm.shutdown();
  exitCode = state.status == RuntimeStatus.halted ? 0 : 1;
}
