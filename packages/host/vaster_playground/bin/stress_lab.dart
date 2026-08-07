import 'dart:io';

import 'package:vaster/vaster.dart';
import 'package:vaster_ast/primitives.dart' show TryCatch;

/// The stress lab: adversarial probes against the framework's edges, with
/// pocket_tasks as the grounding playground. Every probe is free (handler/
/// fake models — fault injection is the point) and prints PASS / FAIL /
/// OBSERVED with the machine's actual behavior. Reads ground in the real
/// repo; stress writes stay on memory mounts.
///
///     dart run vaster_playground:stress_lab <pocketTasksDir>
void main(List<String> args) async {
  final target = Directory(args.isNotEmpty ? args.first : '../pocket_tasks').absolute.path;
  var failures = 0;
  Future<void> probe(String name, Future<String?> Function() body) async {
    try {
      final verdict = await body();
      stdout.writeln(verdict == null ? 'PASS      $name' : 'FAIL      $name — $verdict');
      if (verdict != null) failures++;
    } catch (e) {
      stdout.writeln('BLEW UP   $name — $e');
      failures++;
    }
  }

  // A handler backend that reports MEASURED usage (1000 tokens/call) so
  // budget arithmetic is exact, echoes marker prompts, and fails on demand.
  VasterModel meteredModel({int tokensPerCall = 1000}) => VasterModel.fromHandler((request) async {
    final text = request.messages.last.text;
    if (text.contains('DOOMED')) throw StateError('injected model failure 503');
    return ModelResponse(
      message: ChatMessage.model('echo: $text'),
      finishReason: FinishReason.stop,
      usage: UsageMetadata(
        promptTokenCount: tokensPerCall ~/ 2,
        candidatesTokenCount: tokensPerCall ~/ 2,
        source: UsageSource.measured,
      ),
    );
  }, modelName: 'metered');

  // ── 1. Host budget trips mid-run: the machine stops the spend. ──
  await probe('budget: strict token cap trips the third call', () async {
    final report = await runPipeline(
      const Pipeline(
        name: 'budget_trip',
        children: [
          Prompt(Template.text('one'), output: Binding('a')),
          Prompt(Template.text('two'), output: Binding('b')),
          Prompt(Template.text('three'), output: Binding('c')),
          Prompt(Template.text('four'), output: Binding('d')),
        ],
      ),
      backend: meteredModel(),
      budget: ExecutionBudget(maxTokens: 2500),
    );
    // LEARNED CONTRACT: budget exhaustion is the resource-exhaustion
    // phase (timedOut), not a trap — and the charge is post-call (a
    // call's true cost is unknowable before making it), so consumption
    // may exceed the cap by at most one call.
    if (report.state.status != RuntimeStatus.timedOut) {
      return 'expected timedOut status, got ${report.state.status.name} '
          '(consumed ${report.consumedTokens})';
    }
    if (report.consumedTokens > 3000) return 'overspent by >1 call: ${report.consumedTokens}';
    return null;
  });

  // ── 2. Program-level quota (SetQuotaOp) trips independently. ──
  await probe('quota: program token quota trips', () async {
    final report = await runPipeline(
      const Pipeline(
        name: 'quota_trip',
        children: [
          BudgetScope(maxTokens: 1500),
          Prompt(Template.text('one'), output: Binding('a')),
          Prompt(Template.text('two'), output: Binding('b')),
          Prompt(Template.text('three'), output: Binding('c')),
        ],
      ),
      backend: meteredModel(),
    );
    return report.state.status == RuntimeStatus.error
        ? null
        : 'expected error, got ${report.state.status.name} (${report.consumedTokens} tok)';
  });

  // Program quotas (BudgetScope → SetQuotaOp) TRAP; host budgets time out.
  // Two mechanisms, two fates — both stop the spend.

  // ── 3. SelectModel fallback chain: primary fails, fallback serves. ──
  await probe('models: fallback chain serves after primary fault', () async {
    final report = await runPipeline(
      const Pipeline(
        name: 'fallback_serves',
        result: Binding('answer'),
        children: [
          SelectModel(
            model: ModelDescriptor(provider: 'lab', modelId: 'flaky'),
            fallbacks: [ModelDescriptor(provider: 'lab', modelId: 'steady')],
            child: Prompt(Template.text('serve me'), output: Binding('answer')),
          ),
        ],
      ),
      backend: meteredModel(),
      models: {
        const ModelDescriptor(provider: 'lab', modelId: 'flaky'): VasterModel.fromTextHandler(
          (request) async => throw StateError('flaky backend error 503'),
          modelName: 'flaky',
        ),
        const ModelDescriptor(provider: 'lab', modelId: 'steady'): VasterModel.fromTextHandler(
          (request) async => 'STEADY-ANSWER',
          modelName: 'steady',
        ),
      },
    );
    if (!report.succeeded) return 'run failed: ${report.state.errorDetails}';
    return '${report.result}'.contains('STEADY-ANSWER') ? null : 'wrong server: ${report.result}';
  });

  // ── 4. Unregistered descriptor: the documented default-model escape. ──
  await probe('models: unregistered descriptor falls back to default (observed)', () async {
    final report = await runPipeline(
      const Pipeline(
        name: 'ghost_model',
        result: Binding('answer'),
        children: [
          SelectModel(
            model: ModelDescriptor(provider: 'lab', modelId: 'ghost'),
            child: Prompt(Template.text('who serves?'), output: Binding('answer')),
          ),
        ],
      ),
      backend: meteredModel(),
    );
    if (!report.succeeded) return 'run failed: ${report.state.errorDetails}';
    return '${report.result}'.contains('echo:') ? null : 'unexpected: ${report.result}';
  });

  // ── 5. Agent task model failure: sealed outcome + FAIL-STOP. ──
  // LEARNED CONTRACT: a failed dispatch writes `<out>_outcome` (sealed
  // TaskOutcome kind) AND traps — tolerance is never silent; recovery is
  // explicit (TryCatch / Resilient), and the outcome register survives
  // into the handler's view.
  await probe('agents: model failure = outcome register + fail-stop, recoverable', () async {
    const worker = AgentRole(roleId: 'w', instruction: 'work');
    final report = await runPipeline(
      const Pipeline(
        name: 'outcome_probe',
        result: Binding('after'),
        children: [
          TryCatch(
            tryChildren: [
              Task(agent: worker, prompt: Template.text('this task is DOOMED'), output: Binding('r')),
            ],
            catchChildren: [
              Inputs({Binding('after'): 'recovered-from-model-failure'}),
            ],
          ),
        ],
      ),
      backend: meteredModel(),
    );
    if (!report.succeeded) return 'recovery failed: ${report.state.errorDetails}';
    final outcome = report.state.registers['r_outcome'];
    if ('$outcome' != 'model-failure') return 'r_outcome was $outcome';
    return '${report.result}' == 'recovered-from-model-failure' ? null : 'result: ${report.result}';
  });

  // ── 6. Unresolvable interpolation stays verbatim. ──
  await probe('interpolation: unresolved token travels verbatim', () async {
    String? seen;
    final report = await runPipeline(
      const Pipeline(
        name: 'interp_verbatim',
        children: [Prompt(Template.text('value is \${never_bound}'), output: Binding('x'))],
      ),
      backend: VasterModel.fromTextHandler((request) async {
        seen = request.messages.last.text;
        return 'ok';
      }, modelName: 'observer'),
    );
    if (!report.succeeded) return 'run failed';
    return (seen ?? '').contains(r'${never_bound}') ? null : 'token was mangled: $seen';
  });

  // ── 7. TryCatch recovery around a missing pocket_tasks file. ──
  await probe('errors: TryCatch recovers a missing-file trap', () async {
    final report = await runPipeline(
      Pipeline(
        name: 'trap_recovery',
        result: const Binding('status'),
        mounts: [StorageMount.disk('/project', target)],
        children: const [
          TryCatch(
            tryChildren: [ReadFile.at('/project/planning/DOES_NOT_EXIST.md', output: Binding('doc'))],
            catchChildren: [
              Inputs({Binding('status'): 'recovered'}),
            ],
            error: 'why',
          ),
        ],
      ),
      backend: meteredModel(),
    );
    if (!report.succeeded) return 'did not recover: ${report.state.errorDetails}';
    return '${report.result}' == 'recovered' ? null : 'result: ${report.result}';
  });

  // ── 8. DecideLoop exhaustion takes the default exit. ──
  await probe('decide: loop exhaustion exits via defaultPath', () async {
    var rounds = 0;
    final report = await runPipeline(
      const Pipeline(
        name: 'decide_exhaustion',
        result: Binding('verdict'),
        children: [
          DecideLoop(
            prompt: Template.text('keep going?'),
            body: [Prompt(Template.text('working…'), output: Binding('w'))],
            continueLabel: 'more',
            continueDescription: 'still hungry',
            maxIterations: 2,
            exits: [DecisionPath(label: 'done', description: 'enough')],
            defaultPath: 'done',
            output: Binding('verdict'),
          ),
        ],
      ),
      backend: VasterModel.fromTextHandler((request) async {
        if (request.messages.last.text.contains('keep going')) {
          rounds++;
          return 'more';
        }
        return 'toiling';
      }, modelName: 'stubborn'),
    );
    // LEARNED CONTRACT: the verdict register records the model's LAST
    // label (data); exhaustion is CONTROL — the loop exits regardless.
    // A stubborn model cannot spin the machine.
    if (!report.succeeded) return 'failed: ${report.state.errorDetails}';
    if (rounds > 3) return 'loop ran $rounds decision rounds despite maxIterations 2';
    return '${report.result}' == 'more' ? null : 'verdict: ${report.result} (rounds: $rounds)';
  });

  // ── 9. Provider + Builder: config-driven grounding in the real repo. ──
  await probe('provider: Builder reads provided conventions to ground in plan.md', () async {
    String? seen;
    final report = await runPipeline(
      Pipeline(
        name: 'provider_builder',
        result: const Binding('summary'),
        mounts: [StorageMount.disk('/project', target)],
        children: [
          Provider<SddConventions>(
            value: const SddConventions(root: '/project/planning'),
            children: [
              Builder<SddConventions>(
                (context, conventions) =>
                    ReadFile.at(conventions.planPath, output: const Binding('plan_doc')),
              ),
              const Prompt(Template(['Summarize:\n', Binding('plan_doc')]), output: Binding('summary')),
            ],
          ),
        ],
      ),
      backend: VasterModel.fromTextHandler((request) async {
        seen = request.messages.last.text;
        return 'summarized';
      }, modelName: 'observer'),
    );
    if (!report.succeeded) return 'failed: ${report.state.errorDetails}';
    return (seen ?? '').contains('Pocket Tasks') ? null : 'plan.md content did not reach the prompt';
  });

  // ── 10. The new Author node: discipline suffix + write, on a memory mount. ──
  await probe('author: source discipline appends and the file lands', () async {
    String? seenPrompt;
    final report = await runPipeline(
      const Pipeline(
        name: 'author_probe',
        children: [
          Mount(mount: StorageMount(mountPrefix: '/out')),
          Author.at(
            '/out/gen.dart',
            prompt: Template.text('Write a tiny Dart function.'),
            output: Binding('code'),
            discipline: AuthorDiscipline.source,
          ),
          ReadFile.at('/out/gen.dart', output: Binding('back')),
        ],
      ),
      backend: VasterModel.fromTextHandler((request) async {
        seenPrompt = request.messages.last.text;
        return 'int answer() => 42;';
      }, modelName: 'coder'),
    );
    if (!report.succeeded) return 'failed: ${report.state.errorDetails}';
    if (!(seenPrompt ?? '').contains('no markdown fences')) return 'discipline suffix missing';
    return '${report.state.registers['back']}'.contains('42') ? null : 'file content wrong';
  });

  // ── 11. Caught trap rolls back the open transaction (REL unwinding). ──
  await probe('transactions: caught failure rolls back writes', () async {
    final report = await runPipeline(
      const Pipeline(
        name: 'tx_rollback',
        result: Binding('leak'),
        children: [
          Mount(mount: StorageMount(mountPrefix: '/scratch')),
          TryCatch(
            tryChildren: [
              Transaction(
                children: [
                  WriteFile.at('/scratch/half-done.txt', content: Template.text('partial')),
                  ReadFile.at('/scratch/missing.txt', output: Binding('boom')),
                ],
              ),
            ],
            catchChildren: [
              TryCatch(
                tryChildren: [ReadFile.at('/scratch/half-done.txt', output: Binding('leak'))],
                catchChildren: [
                  Inputs({Binding('leak'): 'ROLLED-BACK'}),
                ],
              ),
            ],
          ),
        ],
      ),
      backend: meteredModel(),
    );
    if (!report.succeeded) return 'failed: ${report.state.errorDetails}';
    return '${report.result}' == 'ROLLED-BACK' ? null : 'partial write leaked: ${report.result}';
  });

  stdout.writeln(failures == 0 ? '\nLAB GREEN' : '\n$failures probe(s) failed');
  exitCode = failures == 0 ? 0 : 1;
}
