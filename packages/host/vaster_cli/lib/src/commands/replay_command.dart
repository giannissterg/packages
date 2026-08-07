import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import '../vaster_command.dart';

/// `vaster replay <envelope> [--diff]` — re-execute a recorded run
/// against its tape (zero tokens, zero network) and, when behavior has
/// changed, say exactly WHAT changed.
///
/// This is agent regression testing as a first-class verb: a faithful
/// replay consumes every recording and exits 0; any divergence — a
/// request the tape doesn't hold, or recordings left unconsumed — exits
/// 1. With `--diff`, a divergence renders a structured report (message-
/// level, char-located) instead of only the typed error.
class ReplayCommand extends VasterCommand {
  @override
  String get name => 'replay';

  @override
  String get description => 'Re-executes a recorded envelope against its tape and reports '
      'divergence — with --diff, down to the character.';

  @override
  ArgParser configureArgs(ArgParser parser) {
    parser.addFlag('diff',
        negatable: false,
        help: 'On divergence, render a structured request diff against '
            'the positional candidate recording (v2 tapes; v1 recordings '
            'name the limitation).');
    parser.addOption('program',
        abbr: 'p',
        help: 'Compiled program (.vbc/.json) for envelopes recorded '
            'before programs were embedded.');
    return parser;
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final results = context.parsedResults;

    if (results.rest.isEmpty) {
      err.writeln('Usage: vaster replay <envelope.json> [--diff]');
      return 1;
    }
    final file = File(results.rest.first);
    if (!file.existsSync()) {
      err.writeln('Error: envelope not found: ${file.path}');
      return 1;
    }

    final ReplayEnvelope envelope;
    try {
      envelope = const ReplayEnvelopeCodec().decodeString(file.readAsStringSync());
    } on Object catch (e) {
      err.writeln('Error: invalid envelope: $e');
      return 1;
    }

    final VasterProgram program;
    final programPath = results['program'] as String?;
    if (programPath != null) {
      final programFile = File(programPath);
      program = programPath.endsWith('.vbc')
          ? VasterProgramBinary.fromBytes(programFile.readAsBytesSync())
          : VasterProgram.fromJson(jsonDecode(programFile.readAsStringSync()) as Map<String, dynamic>);
    } else if (envelope.programJson != null) {
      program = VasterProgram.fromJson(envelope.programJson!);
    } else {
      err.writeln('Error: envelope does not embed its program — pass '
          '--program <compiled.vbc>.');
      return 1;
    }

    final tape = envelope.tape;
    out.writeln('── VASTER REPLAY ───────────────────────────────────────');
    out.writeln('  program : ${program.programName} '
        '(${program.instructions.length} instructions)');
    out.writeln('  tape    : v${tapeVersionOf(tape)} · '
        '${tape.entries.length} recordings · '
        '${tape.recordedModelName ?? 'unknown backend'}');

    final replayModel = ReplayVasterModel(tape: tape);
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    int reportDivergence(TapeDivergenceException e) {
      err.writeln('\n✗ $e');
      if (results['diff'] as bool? ?? false) {
        final candidateIndex = e.callIndex < tape.entries.length ? e.callIndex : null;
        final report = const RequestDiffer().diff(
          live: e.liveRequest,
          candidate: candidateIndex == null ? null : tape.entries[candidateIndex],
          callIndex: e.callIndex,
          candidateIndex: candidateIndex,
        );
        err.writeln(report.render());
      } else {
        err.writeln('\n(re-run with --diff for a structured report)');
      }
      return 1;
    }

    try {
      final state = await runtime.executeProgram(program);
      // Divergence may surface as a trapped error state rather than an
      // exception — the retained typed data is authoritative either way.
      final divergence = replayModel.lastDivergence;
      if (divergence != null) return reportDivergence(divergence);
      out.writeln('  status  : ${state.status.name}');
      if (replayModel.remaining > 0) {
        out.writeln('\n✗ DIVERGED: run completed but ${replayModel.remaining} '
            'recording(s) were never requested — the live behavior makes '
            'fewer/different model calls than the recording.');
        return 1;
      }
      out.writeln('✓ replay faithful: every recording consumed, zero '
          'tokens spent.');
      return 0;
    } on Object {
      final divergence = replayModel.lastDivergence;
      if (divergence != null) return reportDivergence(divergence);
      rethrow;
    } finally {
      await vm.shutdown();
    }
  }

  static int tapeVersionOf(ModelTape tape) =>
      tape.entries.any((e) => e.recorded is FullRecordedRequest) ? 2 : 1;
}
