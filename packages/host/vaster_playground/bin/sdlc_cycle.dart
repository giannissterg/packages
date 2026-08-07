import 'dart:io';

import 'package:vaster/vaster.dart';

/// Dogfood, phase four: the FULL software-engineering cycle.
///
///   1. A product manager writes the PRD (user stories, numbered
///      acceptance criteria).
///   2. A technical manager turns it into a tech design.
///   3. The design becomes a FORMAL task backlog — schema'd JSON in
///      `planning/backlog.json`, the pipeline's ticket system.
///   4. An agent PICKS the next actionable task from the backlog and
///      implements it (file + unit tests, dynamic paths from the ticket).
///   5. Testing, three tiers: UNIT (the generated tests), DEV (the
///      pipeline itself runs `flutter analyze` + `flutter test` in a bash
///      sandbox and a model judges the output — ambiguity fails), and QA
///      (a QA agent verifies each acceptance criterion, writing
///      `planning/qa_report.md`).
///   6. The backlog is updated with the task's outcome.
///
///     dart run vaster_playground:sdlc_cycle <targetDir> \
///         [--backend fake|claude-cli] [--record out.replay.json]
void main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: sdlc_cycle <targetDir> '
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
    sdlcFor(targetDir),
    backend: switch (argOf('backend') ?? 'fake') {
      'claude-cli' => ClaudeCliVasterModel(selectedModel: 'sonnet'),
      _ => fakeTeam(),
    },
    budget: ExecutionBudget(maxCost: 5.0),
    record: argOf('record'),
    // DEV verification runs the real toolchain through the process
    // sandbox; the bash env binds to it by language.
    sandboxes: [ProcessCodeSandbox()],
  );
  print(report);
  exitCode = report.succeeded ? 0 : 1;
}

// ── The team ──────────────────────────────────────────────────────────────

const pm = AgentRole(
  roleId: 'pm',
  title: 'Product Manager',
  instruction:
      'You write product requirement documents a team can build from: crisp user '
      'stories, NUMBERED acceptance criteria (AC-1, AC-2, …), priorities, and explicit '
      'out-of-scope lines. You never design implementations.',
);
const techManager = AgentRole(
  roleId: 'tech_manager',
  title: 'Technical Manager',
  instruction:
      'You turn PRDs into technical designs and formal task breakdowns. Tasks must '
      'be small, independently completable, and ordered by dependency. When asked for JSON '
      'you output RAW JSON ONLY — no fences, no commentary, first character { or [.',
);
const engineer = AgentRole(
  roleId: 'engineer',
  title: 'Software Engineer',
  instruction:
      'You implement exactly the ticket you picked, to the tech design. When asked '
      'for a file you output ONLY the complete raw source — no fences, no commentary.',
);
const qa = AgentRole(
  roleId: 'qa',
  title: 'QA Engineer',
  instruction:
      'You verify implementations against the PRD acceptance criteria one by one, '
      'citing evidence (code, test names, verification output). You never rubber-stamp.',
);

// ── Typed wires ───────────────────────────────────────────────────────────

const specDoc = Binding('spec_doc');
const modelCode = Binding('model_code');
const pubspecDoc = Binding('pubspec_doc');
const prd = Binding('prd');
const design = Binding('design');
const backlog = Binding('backlog');
const picked = Binding('picked');
const taskId = Binding('task_id');
const taskDesc = Binding('task_desc');
const taskFile = Binding('task_file');
const taskTestFile = Binding('task_test_file');
const taskAcceptance = Binding('task_acceptance');
const mainSource = Binding('main_source');
const testSource = Binding('test_source');
const qaReport = Binding('qa_report');
const updatedBacklog = Binding('updated_backlog');

const rawJsonOnly =
    '\n\nOUTPUT RAW JSON ONLY — no markdown fences, no commentary; the first '
    'character of your reply must be { or [.';

Pipeline sdlcFor(String targetDir) => Pipeline(
  name: 'sdlc_cycle',
  result: qaReport,
  mounts: [StorageMount.disk('/project', targetDir)],
  children: [
    const Ground({
      specDoc: '/project/planning/spec.md',
      modelCode: '/project/lib/models/task.dart',
      pubspecDoc: '/project/pubspec.yaml',
    }),

    // ── 1. Product: the PRD ──
    Author.at(
      '/project/planning/prd.md',
      agent: pm,
      output: prd,
      prompt: Template.sections(
        const {'existing spec.md': specDoc, 'current lib/models/task.dart': modelCode},
        lead: const [
          'Write the PRD for the NEXT milestone of Pocket Tasks: task '
              'persistence — tasks survive app restarts. Ground it in what '
              'already exists below. User stories, NUMBERED acceptance '
              'criteria (AC-1…), priorities, and out-of-scope. The milestone '
              'must be deliverable WITHOUT adding package dependencies '
              '(an abstract storage seam now; a real storage backend is a '
              'later milestone).\n',
        ],
      ),
    ),

    // ── 2. Engineering: the tech design ──
    Author.at(
      '/project/planning/tech_design.md',
      agent: techManager,
      output: design,
      prompt: Template.sections(
        const {'prd.md': prd, 'lib/models/task.dart': modelCode, 'pubspec.yaml': pubspecDoc},
        lead: const [
          'Write the technical design for this PRD: component boundaries, '
              'the storage-interface seam, file layout, and the three-tier '
              'test strategy (unit / dev verification / QA acceptance). No '
              'new dependencies in this milestone; name what a later '
              'milestone would swap in.\n',
        ],
      ),
    ),

    // ── 3. The FORMAL backlog: schema'd JSON tickets ──
    Produce(
      agent: techManager,
      output: backlog,
      artifact: '/project/planning/backlog.json',
      schema: const {
        'type': 'object',
        'required': ['tasks'],
        'properties': {
          'tasks': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['id', 'title', 'description', 'file', 'testFile', 'acceptance', 'status'],
              'properties': {
                'id': {'type': 'string'},
                'title': {'type': 'string'},
                'description': {'type': 'string'},
                'file': {'type': 'string', 'description': 'repo-relative primary file'},
                'testFile': {'type': 'string', 'description': 'repo-relative test file'},
                'dependsOn': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'acceptance': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'status': {
                  'type': 'string',
                  'enum': ['todo', 'in_progress', 'done', 'blocked', 'deferred'],
                },
              },
            },
          },
        },
      },
      prompt: Template.sections(
        const {'tech_design.md': design, 'prd.md': prd},
        lead: const [
          'Break the technical design into 2–4 SMALL tasks. Each task: one '
              'repo-relative primary file, one repo-relative test file, the '
              'acceptance criteria ids it satisfies. Tasks needing new '
              'dependencies get status "deferred". Everything else starts '
              '"todo".$rawJsonOnly\n',
        ],
      ),
    ),

    // ── 4. An agent PICKS the next actionable ticket ──
    Produce(
      agent: techManager,
      output: picked,
      schema: const {
        'type': 'object',
        'required': ['id', 'description', 'file', 'testFile', 'acceptance'],
        'properties': {
          'id': {'type': 'string'},
          'description': {'type': 'string'},
          'file': {'type': 'string'},
          'testFile': {'type': 'string'},
          'acceptance': {'type': 'string', 'description': 'the criteria, joined as one string'},
        },
      },
      extract: {
        'id': taskId,
        'description': taskDesc,
        'file': taskFile,
        'testFile': taskTestFile,
        'acceptance': taskAcceptance,
      },
      prompt: Template([
        'From this backlog pick the ONE next actionable task: status "todo", '
            'every dependsOn satisfied, highest value first. Return a JSON '
            'object with EXACTLY these keys: "id", "description", "file" '
            '(the picked task\'s primary file, repo-relative), "testFile" '
            '(its test file, repo-relative), "acceptance" (its criteria '
            'joined as one string). The downstream steps write files at the '
            '"file"/"testFile" paths, so those MUST be the exact '
            'repo-relative paths from the backlog entry.$rawJsonOnly\n\n'
            '--- backlog.json ---\n',
        backlog,
      ]),
    ),

    // ── 5. The engineer implements THE TICKET (paths from the ticket) ──
    // Author applies the source discipline as a TRAILING suffix; the
    // dogfood's prose leak came from a hand-rolled Task+WriteFile pair
    // whose instruction sat at the START of the prompt, far from where
    // the model begins writing.
    Author(
      agent: engineer,
      path: const Template(['/project/', taskFile]),
      output: mainSource,
      discipline: AuthorDiscipline.source,
      prompt: Template.sections(
        const {'the ticket': picked, 'tech_design.md': design, 'current lib/models/task.dart': modelCode},
        lead: const ["Implement exactly this ticket, as the ticket's primary file.\n"],
      ),
    ),
    Author(
      agent: engineer,
      path: const Template(['/project/', taskTestFile]),
      output: testSource,
      discipline: AuthorDiscipline.source,
      prompt: Template.sections(
        const {'the ticket': picked, 'the implementation': mainSource},
        lead: const [
          "Write the ticket's test file (import package:pocket_tasks/…, "
              'use package:flutter_test/flutter_test.dart), covering the '
              "ticket's acceptance criteria.\n",
        ],
      ),
    ),

    // ── 6. DEV verification: the pipeline runs the real toolchain ──
    WriteFile.at(
      '/project/tool/verify.sh',
      content: Template.text(
        '#!/bin/bash\nset -e\ncd $targetDir\n'
        '/Users/giannissterg/dev/flutter/bin/flutter analyze --no-pub\n'
        '/Users/giannissterg/dev/flutter/bin/flutter test\n'
        'echo VERIFY-OK',
      ),
    ),
    Sdd(
      root: '/project/planning',
      children: [
        Sandbox(
          env: const CodeEnvironment(envId: 'devtest', language: SandboxLanguage.bash, timeoutMs: 300000),
          child: Verify(
            envId: 'devtest',
            run: Template.text('bash $targetDir/tool/verify.sh'),
            onFail: [
              // One bounded repair: revise the primary file against the
              // verification output, then QA still sees everything.
              Task(
                agent: engineer,
                output: mainSource,
                prompt: const Template([
                  'The verification run failed. Revise the primary file to fix '
                      'it. Output ONLY the complete raw source — no fences.\n\n'
                      '--- verification output ---\n',
                  Binding('verification'),
                  '\n\n--- the ticket ---\n',
                  picked,
                  '\n\n--- current implementation ---\n',
                  mainSource,
                ]),
              ),
              const WriteFile(path: Template(['/project/', taskFile]), content: Template([mainSource])),
            ],
          ),
        ),
      ],
    ),

    // ── 7. QA: acceptance criteria, one by one ──
    Author.at(
      '/project/planning/qa_report.md',
      agent: qa,
      output: qaReport,
      prompt: Template.sections(
        const {
          'prd.md (acceptance criteria)': prd,
          'the ticket': picked,
          'verification output': Binding('verification'),
          'implementation': mainSource,
          'tests': testSource,
        },
        lead: const [
          'QA review of the implemented ticket: verify EACH acceptance '
              'criterion it claims, citing evidence (code, test names, '
              'verification output). End with an overall PASS or FAIL and '
              'a criteria table.\n',
        ],
      ),
    ),

    // ── 8. Close the loop: the backlog records the outcome ──
    Produce(
      agent: techManager,
      output: updatedBacklog,
      artifact: '/project/planning/backlog.json',
      schema: const {
        'type': 'object',
        'required': ['tasks'],
        'properties': {
          'tasks': {'type': 'array'},
        },
      },
      prompt: Template([
        'Return the backlog below with the completed task\'s status set to '
            '"done" if the QA report passes overall, else "blocked". Change '
            'nothing else.$rawJsonOnly\n\n--- backlog.json ---\n',
        backlog,
        '\n\n--- completed task id ---\n',
        taskId,
        '\n\n--- qa_report.md ---\n',
        qaReport,
      ]),
    ),
  ],
);

// ── Scripted team for the free offline smoke run (the sandbox verify runs
// REAL flutter on the target — the fake code must genuinely pass it). ──

FakeVasterModel fakeTeam() => FakeVasterModel(
  handler: (request) {
    final prompt = request.messages.last.text;
    String reply;
    if (prompt.contains('Write the PRD')) {
      reply =
          '# PRD — Persistence\n\nAC-1: tasks survive restart via a storage seam.\n'
          'AC-2: repository add/toggle/remove update storage.\n';
    } else if (prompt.contains('technical design')) {
      reply =
          '# Tech Design\n\nTaskStore interface + InMemoryTaskStore now; '
          'prefs-backed store deferred.\n';
    } else if (prompt.contains('Break the technical design')) {
      reply =
          '{"tasks":[{"id":"T1","title":"TaskStore seam","description":"Add TaskStore '
          'interface and InMemoryTaskStore with repository logic.","file":'
          '"lib/repositories/task_store.dart","testFile":"test/repositories/task_store_test.dart",'
          '"dependsOn":[],"acceptance":["AC-1","AC-2"],"status":"todo"},'
          '{"id":"T2","title":"Prefs store","description":"shared_preferences-backed store",'
          '"file":"lib/repositories/prefs_store.dart","testFile":"test/repositories/prefs_test.dart",'
          '"dependsOn":["T1"],"acceptance":["AC-1"],"status":"deferred"}]}';
    } else if (prompt.contains('pick the ONE next')) {
      reply =
          '{"id":"T1","description":"Add TaskStore interface and InMemoryTaskStore.",'
          '"file":"lib/repositories/task_store.dart",'
          '"testFile":"test/repositories/task_store_test.dart","acceptance":"AC-1; AC-2"}';
    } else if (prompt.contains('primary file')) {
      reply =
          "import 'package:pocket_tasks/models/task.dart';\n\n"
          'abstract interface class TaskStore {\n'
          '  Future<List<Task>> load();\n  Future<void> save(List<Task> tasks);\n}\n\n'
          'class InMemoryTaskStore implements TaskStore {\n'
          '  List<Task> _tasks = [];\n'
          '  @override\n  Future<List<Task>> load() async => List.of(_tasks);\n'
          '  @override\n  Future<void> save(List<Task> tasks) async => _tasks = List.of(tasks);\n}\n';
    } else if (prompt.contains("Write the ticket's test file")) {
      reply =
          "import 'package:flutter_test/flutter_test.dart';\n"
          "import 'package:pocket_tasks/models/task.dart';\n"
          "import 'package:pocket_tasks/repositories/task_store.dart';\n\n"
          'void main() {\n'
          "  test('save/load round-trip (AC-1, AC-2)', () async {\n"
          '    final store = InMemoryTaskStore();\n'
          "    await store.save([Task(title: 'a')]);\n"
          '    expect((await store.load()).single.title, \'a\');\n  });\n}\n';
    } else if (prompt.contains('verification run failed')) {
      reply = '// unreachable in smoke';
    } else if (prompt.contains('Did verification')) {
      reply = 'pass';
    } else if (prompt.contains('QA review')) {
      reply =
          '# QA Report\n\n| AC | verdict |\n|---|---|\n| AC-1 | PASS |\n| AC-2 | PASS |\n\n'
          'Overall: PASS\n';
    } else if (prompt.contains('status set to')) {
      reply = '{"tasks":[{"id":"T1","status":"done"},{"id":"T2","status":"deferred"}]}';
    } else {
      reply = 'ack';
    }
    return ModelResponse(message: ChatMessage.model(reply));
  },
);
