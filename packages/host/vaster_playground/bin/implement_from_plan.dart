import 'dart:io';

import 'package:vaster/vaster.dart';

/// Dogfood, phase two: the framework WRITES CODE into another codebase.
///
/// Reads the target's committed `planning/plan.md` AND the reviewer's
/// `planning/review.md` (which demanded blocking fixes), implements the
/// task model plus its unit tests as real files under `lib/` and `test/`,
/// then reviews its own output — budget-capped and recorded. Correctness
/// is judged OUTSIDE the framework afterwards: `flutter analyze` and
/// `flutter test` on the target repo.
///
///     dart run vaster_playground:implement_from_plan <targetDir> \
///         [--backend fake|claude-cli] [--record out.replay.json]
void main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: implement_from_plan <targetDir> '
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
    implementFor(targetDir),
    backend: switch (argOf('backend') ?? 'fake') {
      'claude-cli' => ClaudeCliVasterModel(selectedModel: 'sonnet'),
      _ => fakeEngineer(),
    },
    // Capability demo: the run cannot exceed this spend, enforced by the
    // machine, not by hope.
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
      'You write production Dart/Flutter code exactly to plan. When asked for a file '
      'you output ONLY the complete raw source — no markdown fences, no commentary, no '
      'surrounding prose. You apply review feedback precisely.',
);
const reviewer = AgentRole(
  roleId: 'reviewer',
  title: 'Staff Engineer',
  instruction:
      'You review code rigorously against its plan and prior review feedback: '
      'correctness, API contracts, test quality. You verify previously-demanded fixes '
      'actually landed.',
);

// Typed wires, declared once (AST_REVIEW F1/F7 style).
const plan = Binding('plan');
const review = Binding('review');
const pubspec = Binding('pubspec');
const modelSource = Binding('model_source');
const testSource = Binding('test_source');
const codeReview = Binding('code_review');

Pipeline implementFor(String targetDir) => Pipeline(
  name: 'implement_task_model',
  result: codeReview,
  mounts: [StorageMount.disk('/project', targetDir)],
  children: [
    // Ground in the REAL committed artifacts: the plan AND the review
    // whose blocking fixes the implementation must apply.
    const Ground({
      plan: '/project/planning/plan.md',
      review: '/project/planning/review.md',
      pubspec: '/project/pubspec.yaml',
    }),
    Author.at(
      '/project/lib/models/task.dart',
      agent: engineer,
      output: modelSource,
      discipline: AuthorDiscipline.source,
      prompt: Template.sections(
        const {'pubspec.yaml': pubspec, 'plan.md': plan, 'review.md (blocking fixes to apply)': review},
        lead: const [
          'Implement `lib/models/task.dart` for the Flutter package below — '
              'the immutable Task value type from milestone A2 of the plan, '
              'WITH every blocking fix the review demands (the private '
              'restore constructor for fromJson, the explicit createdAt '
              'default, the corrected copyWith contract). Pure Dart, no '
              'Flutter imports, no new dependencies.\n',
        ],
      ),
    ),
    Author.at(
      '/project/test/models/task_test.dart',
      agent: engineer,
      output: testSource,
      discipline: AuthorDiscipline.source,
      prompt: Template.sections(
        const {'lib/models/task.dart': modelSource},
        lead: const [
          'Write `test/models/task_test.dart` for the Task model below '
              '(package name: pocket_tasks — import it as '
              "package:pocket_tasks/models/task.dart). Cover: JSON "
              'round-trip preserving id and createdAt, copyWith field '
              'updates, toggle/done semantics if present, and unique id '
              'generation. Use package:flutter_test/flutter_test.dart.\n',
        ],
      ),
    ),
    const Review(
      agent: reviewer,
      of: '/project/lib/models/task.dart',
      artifact: '/project/planning/code_review.md',
      output: codeReview,
    ),
  ],
);

/// Scripted engineer for the free offline smoke run.
FakeVasterModel fakeEngineer() => FakeVasterModel(
  handler: (request) {
    final prompt = request.messages.last.text;
    final text = prompt.contains('Review the artifact')
        ? '# Code Review\n\nAPPROVE — (fake)'
        : prompt.contains('approved or sent back')
        ? 'approve'
        : prompt.contains('task_test.dart')
        ? "import 'package:flutter_test/flutter_test.dart';\n"
              "import 'package:pocket_tasks/models/task.dart';\n\n"
              "void main() {\n  test('round-trip', () {\n"
              "    final t = Task(title: 'x');\n"
              '    expect(Task.fromJson(t.toJson()).id, t.id);\n  });\n}\n'
        : 'class Task {\n  final String id;\n  final String title;\n'
              '  final DateTime createdAt;\n'
              '  Task({required this.title, DateTime? createdAt})\n'
              '      : id = DateTime.now().microsecondsSinceEpoch.toString(),\n'
              '        createdAt = createdAt ?? DateTime.now();\n'
              '  Task._restore({required this.id, required this.title, required this.createdAt});\n'
              '  Map<String, dynamic> toJson() => {\n'
              "        'id': id,\n        'title': title,\n"
              "        'createdAt': createdAt.toIso8601String(),\n      };\n"
              '  factory Task.fromJson(Map<String, dynamic> json) => Task._restore(\n'
              "        id: json['id'] as String,\n        title: json['title'] as String,\n"
              "        createdAt: DateTime.parse(json['createdAt'] as String),\n      );\n}\n";
    return ModelResponse(message: ChatMessage.model(text));
  },
);
