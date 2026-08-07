import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart' show AgentRole;
import 'package:vaster_eval/vaster_eval.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// One reliability benchmark: a workflow, the semantics it exercises, how
/// to score it, and how to build its zero-cost CI variant (recorded tape
/// or deterministic fault injection).
///
/// Tape benchmarks replay REAL recorded backend traffic (the program rides
/// the envelope — no duplicated pipeline sources); fault benchmarks compile
/// from the AST and inject failures a live backend cannot produce on
/// demand. Together they are gate 4's evidence: the reliability semantics
/// hold under faults on every push, and real-model fidelity is locked to
/// the recorded numbers.
final class ReliabilityBenchmark {
  final String id;

  /// Which reliability semantics this measures (published table column).
  final String exercises;

  /// `tape:<backend>` for recorded real traffic, `fault:<shape>` for
  /// deterministic injection.
  final String backendLabel;

  final Scorer scorer;

  /// Trials per CI run (tapes are deterministic — one is proof; fault
  /// benchmarks run more to demonstrate repeatability).
  final int ciTrials;

  final VasterProgram Function() program;
  final Future<VasterVirtualMachine> Function() ciVm;

  /// Exact recorded totals for tape benchmarks — the fidelity lock. Null
  /// for fault benchmarks (fakes estimate, they don't measure).
  final int? expectedTokens;
  final double? expectedCostUsd;

  /// Whether `vaster eval` can run this against a live backend as-is
  /// (fault benchmarks need their injection models registered — CI only).
  final bool liveRunnable;

  const ReliabilityBenchmark({
    required this.id,
    required this.exercises,
    required this.backendLabel,
    required this.scorer,
    required this.program,
    required this.ciVm,
    this.ciTrials = 3,
    this.expectedTokens,
    this.expectedCostUsd,
    this.liveRunnable = true,
  });

  EvalVariant ciVariant() => EvalVariant(
    label: '$id [$backendLabel]',
    program: program(),
    vmFactory: ciVm,
    dispose: (vm) => (vm as VasterVMEngine).shutdown(),
  );
}

/// The benchmark set (see `docs/RELIABILITY.md` for the published numbers
/// and the live-run protocol). Const-constructible registry per the house
/// rule — behavior in an instance class, `builtin` as the canonical
/// instance.
final class ReliabilityBenchmarks {
  final List<ReliabilityBenchmark> all;

  const ReliabilityBenchmarks(this.all);

  static final ReliabilityBenchmarks builtin = ReliabilityBenchmarks([
    _sddMultiAgent(),
    _storyLinesLlama(),
    _retryHeals(),
    _fallbackServes(),
    _effectsOnce(),
    _agentEffectsOnce(),
  ]);

  // ── Tape benchmarks: real recorded backend traffic ─────────────────────

  /// Locates a fixture whether tests run from the package dir or the
  /// workspace root (the sweep does the former, IDEs often the latter).
  static File _fixture(String name) =>
      ['../vaster_playground/test/fixtures/$name', 'packages/host/vaster_playground/test/fixtures/$name']
          .map(File.new)
          .firstWhere((f) => f.existsSync(), orElse: () => throw StateError('fixture not found: $name'));

  static ReplayEnvelope _envelope(String name) =>
      const ReplayEnvelopeCodec().decodeString(_fixture(name).readAsStringSync());

  /// Three-role SDD pipeline (Specify → Plan → Review): transactional
  /// `Task`s, agent sessions, artifact writes — replayed against the real
  /// claude-cli run of 2026-08-05 with its exact wire-reported usage.
  static ReliabilityBenchmark _sddMultiAgent() => ReliabilityBenchmark(
    id: 'sdd_multi_agent',
    exercises:
        'multi-agent Tasks (transactional by default), '
        'sessions, artifact writes, usage fidelity',
    backendLabel: 'tape:claude-cli',
    scorer: const AllOfScorer([HaltedScorer(), ContainsScorer('APPROVE')]),
    ciTrials: 1,
    expectedTokens: 450302,
    expectedCostUsd: 0.825917,
    program: () => VasterProgram.fromJson(_envelope('sdd_fidelity.replay.json').programJson!),
    ciVm: () async => VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: ReplayVasterModel(tape: _envelope('sdd_fidelity.replay.json').tape)),
    ),
  );

  /// Iterative story pipeline on a real LOCAL model (llama-ffi,
  /// stories15M) — the second real backend on tape.
  static ReliabilityBenchmark _storyLinesLlama() => ReliabilityBenchmark(
    id: 'story_lines_llama',
    exercises:
        'prompt chaining, local-inference fidelity '
        '(second real backend)',
    backendLabel: 'tape:llama-ffi',
    scorer: const HaltedScorer(),
    ciTrials: 1,
    program: () => VasterProgram.fromJson(_envelope('story_lines_v2.replay.json').programJson!),
    ciVm: () async => VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: ReplayVasterModel(tape: _envelope('story_lines_v2.replay.json').tape)),
    ),
  );

  // ── Fault benchmarks: deterministic injection, CI-only ─────────────────

  static VasterProgram _compile(List<VasterNode> children, {required String result}) =>
      const BasicWorkflowCompiler().compile(
        Pipeline(name: 'benchmark', result: Binding(result), children: children),
      );

  /// `Resilient` heals a transient outage: the model dies twice with a
  /// 500, the third attempt serves. One success within the declared
  /// ceiling = the retry loop works.
  static ReliabilityBenchmark _retryHeals() => ReliabilityBenchmark(
    id: 'retry_heals',
    exercises:
        'Resilient retry loop (REL-P2): transient failures '
        'heal within the declared ceiling',
    backendLabel: 'fault:500-500-ok',
    scorer: const AllOfScorer([HaltedScorer(), ContainsScorer('recovered')]),
    program: () => _compile([
      const Resilient(
        attempts: 3,
        child: Prompt(Template.text('fetch the status'), output: Binding('status')),
      ),
    ], result: 'status'),
    ciVm: () async {
      var calls = 0;
      return VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: FakeVasterModel(
            handler: (request) {
              calls++;
              if (calls <= 2) throw StateError('API error 500 outage');
              return ModelResponse(message: ChatMessage.model('the service recovered'));
            },
          ),
        ),
      );
    },
  );

  /// A dead primary falls through a declared `SelectModel` chain; the
  /// fallback member serves the call.
  static ReliabilityBenchmark _fallbackServes() => ReliabilityBenchmark(
    id: 'fallback_serves',
    exercises:
        'SelectModel fallback chain (REL-P3): model-kind '
        'failure falls through, fallback serves',
    backendLabel: 'fault:dead-primary',
    scorer: const AllOfScorer([HaltedScorer(), ContainsScorer('from the fallback')]),
    liveRunnable: false,
    program: () => _compile([
      const SelectModel(
        model: ModelDescriptor(provider: 'bench_down', modelId: 'p'),
        fallbacks: [ModelDescriptor(provider: 'bench_up', modelId: 'f')],
        child: Prompt(Template.text('answer the question'), output: Binding('answer')),
      ),
    ], result: 'answer'),
    ciVm: () async {
      final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
      vm.registerModel(
        const ModelDescriptor(provider: 'bench_down', modelId: 'p'),
        FakeVasterModel(modelName: 'bench-down', handler: (_) => throw StateError('API error 503 dead')),
      );
      vm.registerModel(
        const ModelDescriptor(provider: 'bench_up', modelId: 'f'),
        FakeVasterModel(modelName: 'bench-up', defaultResponseText: 'from the fallback'),
      );
      return vm;
    },
  );

  /// The REL-P4 exactly-once claim, scored: the model calls a
  /// side-effecting tool, dies mid-turn, and the retried attempt REPLAYS
  /// the tool result. The tool reports its own execution count in its
  /// result; the final answer must carry `executions=1`.
  static ReliabilityBenchmark _effectsOnce() => ReliabilityBenchmark(
    id: 'effects_once',
    exercises:
        'effect ledger (REL-P4): a retried turn replays tool '
        'results instead of re-executing side effects',
    backendLabel: 'fault:die-after-tool',
    scorer: const AllOfScorer([HaltedScorer(), ContainsScorer('executions=1')]),
    liveRunnable: false,
    program: () => _compile([
      const Resilient(
        attempts: 3,
        child: Prompt(Template.text('send the alert'), output: Binding('outcome')),
      ),
    ], result: 'outcome'),
    ciVm: () async {
      var generateCalls = 0;
      var executions = 0;
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: FakeVasterModel(
            handler: (request) {
              generateCalls++;
              switch (generateCalls) {
                case 1: // attempt 1: call the tool
                case 3: // attempt 2: same call again
                  return ModelResponse(
                    message: ChatMessage(
                      role: Role.model,
                      parts: [
                        const TextPart('Sending.'),
                        FunctionCallPart(
                          callId: 'c$generateCalls',
                          name: 'send_alert',
                          arguments: const {'msg': 'deploy failed'},
                        ),
                      ],
                    ),
                    finishReason: FinishReason.toolCalls,
                  );
                case 2: // attempt 1 dies AFTER the tool executed
                  throw StateError('API error 500 mid-turn');
                default: // attempt 2 continuation: report the count it saw
                  final toolCount = request.messages
                      .expand((m) => m.parts)
                      .whereType<FunctionResponsePart>()
                      .map((p) => p.response['count'])
                      .lastOrNull;
                  return ModelResponse(message: ChatMessage.model('done, executions=$toolCount'));
              }
            },
          ),
        ),
      );
      vm.registerTool(
        FunctionTool.define(
          name: 'send_alert',
          description: 'Send an alert (non-compensable)',
          parametersSchema: const {
            'type': 'object',
            'properties': {
              'msg': {'type': 'string'},
            },
          },
          handler: (args) {
            executions++;
            return {'status': 'sent', 'count': executions};
          },
        ),
      );
      return vm;
    },
  );

  /// GAP-3a's parity claim, scored: the tool call happens INSIDE an agent
  /// task; the task dies after the tool ran; the retried dispatch re-runs
  /// the agent, whose tool call REPLAYS through its effect region. The
  /// tool reports its execution count; the answer must carry
  /// `executions=1`.
  static ReliabilityBenchmark _agentEffectsOnce() => ReliabilityBenchmark(
    id: 'agent_effects_once',
    exercises:
        'agent-internal effect replay (GAP-3a): a re-dispatched '
        'task never re-executes its predecessor\'s tool effects',
    backendLabel: 'fault:die-mid-task',
    scorer: const AllOfScorer([HaltedScorer(), ContainsScorer('executions=1')]),
    liveRunnable: false,
    program: () => const BasicWorkflowCompiler().compile(
      Pipeline(
        name: 'benchmark',
        result: Binding('outcome'),
        roles: [
          AgentRole(
            roleId: 'notifier',
            name: 'Notifier',
            title: 'Operator Notifier',
            instruction: 'Send alerts.',
          ),
        ],
        children: [
          Resilient(
            attempts: 3,
            child: Task(
              agentId: 'notifier',
              prompt: Template.text('alert the operator'),
              output: Binding('outcome'),
            ),
          ),
        ],
      ),
    ),
    ciVm: () async {
      var generateCalls = 0;
      var executions = 0;
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: FakeVasterModel(
            handler: (request) {
              generateCalls++;
              switch (generateCalls) {
                case 1: // attempt 1, agent turn 1: call the tool
                case 3: // attempt 2 re-dispatch: same call
                  return ModelResponse(
                    message: ChatMessage(
                      role: Role.model,
                      parts: [
                        const TextPart('Alerting.'),
                        FunctionCallPart(
                          callId: 'c$generateCalls',
                          name: 'send_alert',
                          arguments: const {'msg': 'disk full'},
                        ),
                      ],
                    ),
                    finishReason: FinishReason.toolCalls,
                  );
                case 2: // attempt 1 dies AFTER the tool executed
                  throw StateError('API error 500 mid-task');
                default:
                  final count = request.messages
                      .expand((m) => m.parts)
                      .whereType<FunctionResponsePart>()
                      .map((p) => p.response['count'])
                      .lastOrNull;
                  return ModelResponse(message: ChatMessage.model('done, executions=$count'));
              }
            },
          ),
        ),
      );
      vm.registerTool(
        FunctionTool.define(
          name: 'send_alert',
          description: 'Send an alert (non-compensable)',
          parametersSchema: const {
            'type': 'object',
            'properties': {
              'msg': {'type': 'string'},
            },
          },
          handler: (args) {
            executions++;
            return {'status': 'sent', 'count': executions};
          },
        ),
      );
      return vm;
    },
  );
}

/// Renders an [EvalReport]-per-benchmark set as the markdown table
/// `docs/RELIABILITY.md` publishes.
String renderBenchmarkTable(List<({ReliabilityBenchmark benchmark, VariantReport report})> rows) {
  final buffer = StringBuffer()
    ..writeln(
      '| benchmark | exercises | backend | trials | success | '
      'tokens | cost |',
    )
    ..writeln('|---|---|---|---|---|---|---|');
  for (final row in rows) {
    final r = row.report;
    buffer.writeln(
      '| ${row.benchmark.id} '
      '| ${row.benchmark.exercises} '
      '| ${row.benchmark.backendLabel} '
      '| ${r.trialCount} '
      '| ${r.passed}/${r.trialCount} '
      '| ${r.totalTokens} '
      '| ${r.totalCostUsd > 0 ? '\$${r.totalCostUsd.toStringAsFixed(6)}' : '—'} |',
    );
  }
  return buffer.toString();
}

/// JSON-encodes the full set's reports (machine-readable publication).
String encodeBenchmarkReports(List<({ReliabilityBenchmark benchmark, VariantReport report})> rows) =>
    const JsonEncoder.withIndent('  ').convert([
      for (final row in rows)
        {
          'id': row.benchmark.id,
          'exercises': row.benchmark.exercises,
          'backend': row.benchmark.backendLabel,
          ...row.report.toJson(),
        },
    ]);
