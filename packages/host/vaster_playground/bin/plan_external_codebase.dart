import 'dart:io';

import 'package:vaster/vaster.dart';

/// Dogfood: point the framework at ANOTHER codebase and have it produce a
/// reviewed development plan, written INTO that codebase.
///
/// The pipeline disk-mounts the target project at `/project`, reads its
/// real files into bindings, and runs the SDD kit (Specify → Plan →
/// Review) grounded in that content. Artifacts land in
/// `<target>/planning/`; the run can record a replay envelope for
/// `vaster debug` / `--resume-at`.
///
/// This file is the AST_REVIEW benchmark: its length is the measure of
/// consumer-facing verbosity. W0 (runPipeline) landed; W1–W3 shrink the
/// tree itself.
///
///     dart run vaster_playground:plan_external_codebase <targetDir> \
///         [--backend fake|claude-cli] [--record out.replay.json]
void main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: plan_external_codebase <targetDir> '
      '[--backend fake|claude-cli] [--record out.replay.json]',
    );
    exitCode = 1;
    return;
  }
  final targetDir = Directory(positional.first).absolute.path;
  String? argOf(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final report = await runPipeline(
    planFor(targetDir),
    backend: switch (argOf('backend') ?? 'fake') {
      'claude-cli' => ClaudeCliVasterModel(selectedModel: 'sonnet'),
      _ => fakePlanner(),
    },
    record: argOf('record'),
  );
  print(report);
  exitCode = report.succeeded ? 0 : 1;
}

// ── The pipeline: three roles plan someone else's codebase ──

const architect = AgentRole(
  roleId: 'architect',
  title: 'Flutter Product Architect',
  instruction:
      'You write precise, reviewable product specifications for Flutter apps. '
      'You ground every claim in the actual code you are shown — never invent files.',
);
const lead = AgentRole(
  roleId: 'lead',
  title: 'Flutter Tech Lead',
  instruction:
      'You turn specifications into concrete, ordered implementation plans: '
      'exact files to create or modify, package choices with rationale, and a test strategy.',
);
const reviewer = AgentRole(
  roleId: 'reviewer',
  title: 'Staff Engineer',
  instruction:
      'You review plans rigorously: feasibility, ordering, missing work, '
      'testability. You call out anything not grounded in the real codebase.',
);

// Typed dataflow wires (F1/F7): declared once, referenced everywhere —
// no escaped-dollar strings, no magic names.
const pubspec = Binding('pubspec');
const mainDart = Binding('main_dart');
const review = Binding('review');

Pipeline planFor(String targetDir) => Pipeline(
  name: 'external_codebase_plan',
  result: review,
  // No roles list (F2): the compiler collects the roles the tree names.
  mounts: [StorageMount.disk('/project', targetDir)],
  children: const [
    Sdd(
      root: '/project/planning',
      children: [
        // Ground the pipeline in the REAL codebase: these are actual
        // file reads through the disk mount, not pasted context.
        ReadFile.at('/project/pubspec.yaml', output: pubspec),
        ReadFile.at('/project/lib/main.dart', output: mainDart),
        Specify(
          agent: architect,
          goal: Template([
            'Turn this freshly generated Flutter starter into "Pocket Tasks" — '
                'a small offline-first personal task manager: task list with '
                'add/edit/complete/delete, local persistence that survives restarts, '
                'light/dark theming, and meaningful widget tests. Scope it as ONE '
                'incremental milestone an individual developer ships in a week.\n\n'
                'The ACTUAL current codebase you are planning against:\n\n'
                '--- pubspec.yaml ---\n',
            pubspec,
            '\n\n--- lib/main.dart ---\n',
            mainDart,
          ]),
        ),
        Plan(agent: lead),
        Review(agent: reviewer, output: review),
      ],
    ),
  ],
);

/// Scripted responses for the free offline smoke run. Order matters: the
/// review prompt embeds the plan it reviews, so sniff the most specific
/// phase first.
FakeVasterModel fakePlanner() => FakeVasterModel(
  handler: (request) {
    final prompt = request.messages.last.text;
    final text = prompt.contains('Review')
        ? '# Review\n\nAPPROVE — (fake review)'
        : prompt.contains('specification')
        ? '# Pocket Tasks — Specification\n\n(fake spec)'
        : '# Implementation Plan\n\n1. (fake step)';
    return ModelResponse(message: ChatMessage.model(text));
  },
);
