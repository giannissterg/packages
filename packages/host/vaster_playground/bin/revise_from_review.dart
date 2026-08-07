import 'dart:io';

import 'package:vaster/vaster.dart';

/// Dogfood, phase three: the framework CLOSES ITS OWN REVIEW LOOP.
///
/// The previous run's reviewer REVISE'd the generated Task model (clock-
/// based id collision risk, missing `==`/`hashCode`). This pipeline
/// applies those fixes with [Author], revises the tests to match, then
/// runs `Review(revise: …)` — the self-revising loop: on a REVISE
/// verdict the artifact is regenerated with the critique bound into the
/// prompt and re-reviewed, up to two rounds. Exhaustion approves —
/// an endless review cycle must not hang the pipeline.
///
///     dart run vaster_playground:revise_from_review <targetDir> \
///         [--backend fake|claude-cli] [--record out.replay.json]
void main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: revise_from_review <targetDir> '
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
    reviseFor(targetDir),
    backend: switch (argOf('backend') ?? 'fake') {
      'claude-cli' => ClaudeCliVasterModel(selectedModel: 'sonnet'),
      _ => fakeReviser(),
    },
    budget: ExecutionBudget(maxCost: 3.0),
    record: argOf('record'),
  );
  print(report);
  exitCode = report.succeeded ? 0 : 1;
}

const engineer = AgentRole(
  roleId: 'engineer',
  title: 'Flutter Engineer',
  instruction:
      'You revise production Dart code to address review findings precisely, '
      'preserving public contracts unless the review demands otherwise. When asked for a '
      'file you output ONLY the complete raw source — no fences, no commentary.',
);
const reviewer = AgentRole(
  roleId: 'reviewer',
  title: 'Staff Engineer',
  instruction:
      'You review code rigorously and verify demanded fixes actually landed. '
      'Hold code to a shipping standard, not a perfection standard.',
);

// Typed wires.
const priorReview = Binding('prior_review');
const modelSource = Binding('model_source');
const testSource = Binding('test_source');
const finalReview = Binding('final_review');

Pipeline reviseFor(String targetDir) => Pipeline(
  name: 'revise_task_model',
  result: finalReview,
  mounts: [StorageMount.disk('/project', targetDir)],
  children: const [
    Ground({priorReview: '/project/planning/code_review.md'}),
    Revise(
      agent: engineer,
      path: '/project/lib/models/task.dart',
      output: modelSource,
      addressing: Template([
        'EVERY blocking issue in the review below: a collision-proof id '
            '(no new dependencies — a monotonic counter combined with the '
            'timestamp is acceptable), value equality (`operator ==` and '
            '`hashCode` over all fields), a `toString`, and remove `id` '
            'from `copyWith`. Keep the `_restore`-based `fromJson` contract '
            'and the `createdAt` default.\n\n--- review ---\n',
        priorReview,
      ]),
    ),
    Author.at(
      '/project/test/models/task_test.dart',
      agent: engineer,
      output: testSource,
      discipline: AuthorDiscipline.source,
      prompt: Template([
        'Rewrite test/models/task_test.dart for the REVISED Task model '
            'below (import package:pocket_tasks/models/task.dart, use '
            'package:flutter_test/flutter_test.dart). Cover: JSON '
            'round-trip, copyWith (which no longer exposes id), value '
            'equality and hashCode, toString, and id uniqueness under '
            'rapid successive construction (create 100 tasks in a tight '
            'loop and assert all ids are distinct).\n\n'
            '--- revised lib/models/task.dart ---\n',
        modelSource,
      ]),
    ),
    // The self-closing loop: on REVISE, regenerate WITH the critique
    // bound in, then re-review — bounded, so a harsh reviewer cannot
    // spin the machine.
    Review(
      agent: reviewer,
      of: '/project/lib/models/task.dart',
      artifact: '/project/planning/code_review_round2.md',
      output: finalReview,
      maxRounds: 2,
      revise: Author.at(
        '/project/lib/models/task.dart',
        agent: engineer,
        output: modelSource,
        discipline: AuthorDiscipline.source,
        prompt: Template([
          'Revise this Dart file to address every blocking issue in the '
              'new review below. Do not regress previously fixed items.\n\n'
              '--- current file ---\n',
          modelSource,
          '\n\n--- new review ---\n',
          finalReview,
        ]),
      ),
    ),
  ],
);

/// Scripted responses for the free offline smoke run.
FakeVasterModel fakeReviser() => FakeVasterModel(
  handler: (request) {
    final prompt = request.messages.last.text;
    final text = prompt.contains('Review the artifact')
        ? '# Round 2\n\nAPPROVE — fixes landed (fake)'
        : prompt.contains('approved or sent back')
        ? 'approve'
        : prompt.contains('task_test.dart')
        ? "import 'package:flutter_test/flutter_test.dart';\n"
              "import 'package:pocket_tasks/models/task.dart';\n\n"
              "void main() {\n  test('ids unique', () {\n"
              "    final ids = {for (var i = 0; i < 100; i++) Task(title: 't\$i').id};\n"
              '    expect(ids.length, 100);\n  });\n}\n'
        : 'class Task {\n  static int _seq = 0;\n  final String id;\n  final String title;\n'
              '  final DateTime createdAt;\n'
              '  Task({required this.title, DateTime? createdAt})\n'
              "      : id = '\${DateTime.now().microsecondsSinceEpoch}-\${_seq++}',\n"
              '        createdAt = createdAt ?? DateTime.now();\n'
              '  Task._restore({required this.id, required this.title, required this.createdAt});\n'
              '  @override\n  bool operator ==(Object other) =>\n'
              '      other is Task && other.id == id && other.title == title && '
              'other.createdAt == createdAt;\n'
              '  @override\n  int get hashCode => Object.hash(id, title, createdAt);\n'
              "  @override\n  String toString() => 'Task(\$id, \$title)';\n"
              '  Map<String, dynamic> toJson() =>\n'
              "      {'id': id, 'title': title, 'createdAt': createdAt.toIso8601String()};\n"
              '  factory Task.fromJson(Map<String, dynamic> json) => Task._restore(\n'
              "        id: json['id'] as String,\n        title: json['title'] as String,\n"
              "        createdAt: DateTime.parse(json['createdAt'] as String),\n      );\n}\n";
    return ModelResponse(message: ChatMessage.model(text));
  },
);
