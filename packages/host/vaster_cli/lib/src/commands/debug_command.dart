import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_debug/vaster_debug.dart';
import 'package:vaster_dis/tracer.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_vm/vaster_vm.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

/// Time-travel debugger over a recorded execution envelope.
///
/// Journal views (registers, deltas, call stack, listing) are instant and
/// pure; `vfs`/`cat`/`ctx` materialize state at the cursor by verified tape
/// replay (see `DebugSession`).
class DebugCommand extends VasterCommand {
  @override
  String get name => 'debug';

  @override
  String get description => 'Time-travel debugger over a recorded envelope: step forward/back '
      'through a run, inspecting registers, VFS, and context at any step.';

  @override
  ArgParser configureArgs(ArgParser parser) {
    parser.addOption(
      'program',
      abbr: 'p',
      help: 'Compiled program (.vbc/.json) for envelopes recorded before '
          'programs were embedded.',
    );
    parser.addOption(
      'script',
      abbr: 's',
      help: 'Semicolon/newline-separated debugger commands to execute '
          'non-interactively (e.g. "seek 12; regs; cat /workspace/spec.md").',
    );
    parser.addOption(
      'resume-at',
      help: 'TT-P4: resume LIVE execution from recorded step N — the state '
          'after step N is reconstructed by verified tape replay, then '
          'execution continues on the --backend model (the prefix is never '
          're-paid).',
    );
    parser.addOption(
      'backend',
      help: 'Model backend for --resume-at '
          '(fake|claude-api|claude-cli|gemini|gemini-cli|llama|rpc).',
    );
    parser.addOption('model', help: 'Backend-specific model name for --resume-at.');
    parser.addFlag('trace', negatable: false, help: 'Live disassembly trace while resuming.');
    return parser;
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final args = context.parsedResults.rest;

    if (args.isEmpty) {
      err.writeln('Error: Missing envelope path.');
      err.writeln('Usage: vaster debug <envelope.json> '
          '[--program prog.vbc] [--script "cmd; cmd"]');
      return 1;
    }
    final envelopeFile = File(args.first);
    if (!envelopeFile.existsSync()) {
      err.writeln('Error: File not found at ${args.first}');
      return 1;
    }

    VasterProgram? programOverride;
    final programPath = context.parsedResults['program'] as String?;
    if (programPath != null) {
      final file = File(programPath);
      programOverride = programPath.endsWith('.vbc')
          ? VasterProgramBinary.fromBytes(file.readAsBytesSync())
          : VasterProgram.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    }

    final DebugSession session;
    try {
      session = DebugSession.load(
        DebugEnvelope.parse(
          envelopeFile.readAsStringSync(),
          programOverride: programOverride,
        ),
        // Hosts own composition (B1): the CLI supplies the engine.
        vmFactory: (replayModel) => VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel)),
      );
    } on StateError catch (e) {
      err.writeln('Error: ${e.message}');
      return 1;
    }

    out.writeln('── VASTER TIME-TRAVEL DEBUGGER ─────────────────────────');
    out.writeln('  program : ${session.program.programName} '
        '(${session.program.instructions.length} instructions)');
    out.writeln('  journal : ${session.length} steps · '
        'tape: ${session.tapeEntries.length} model calls');
    for (final warning in session.warnings) {
      out.writeln('  ⚠ $warning');
    }
    _printFrame(session, out);

    final resumeAtRaw = context.parsedResults['resume-at'] as String?;
    final script = context.parsedResults['script'] as String?;
    if (resumeAtRaw != null) {
      if (script != null) {
        err.writeln('Error: --resume-at and --script are mutually exclusive.');
        return 1;
      }
      final step = int.tryParse(resumeAtRaw);
      if (step == null || step < 0 || step > session.length - 1) {
        err.writeln('Error: --resume-at must be a step in 0..${session.length - 1} '
            '(this recording has ${session.length} steps).');
        return 1;
      }
      return _resumeLive(session, step, context, out, err);
    }

    if (script != null) {
      for (final raw in script.split(RegExp(r'[;\n]'))) {
        final command = raw.trim();
        if (command.isEmpty) continue;
        out.writeln('(vdb) $command');
        final keepGoing = await _dispatch(command, session, out, err);
        if (!keepGoing) break;
      }
      return 0;
    }

    // Interactive loop (mirrors the HITL readLineSync precedent).
    while (true) {
      out.write('(vdb) ');
      final line = stdin.readLineSync()?.trim();
      if (line == null) return 0; // EOF
      if (line.isEmpty) continue;
      final keepGoing = await _dispatch(line, session, out, err);
      if (!keepGoing) return 0;
    }
  }

  /// TT-P4: the surgery table. Reconstructs the machine after [step] by
  /// verified tape replay, captures it as a [MachineCheckpoint], restores
  /// it into a fresh VM whose default model is the LIVE backend, and runs
  /// to completion — the recorded prefix is never re-paid.
  Future<int> _resumeLive(
    DebugSession session,
    int step,
    CommandContext context,
    StringSink out,
    StringSink err,
  ) async {
    session.seek(step);
    out.writeln('\n── LIVE RESUME (TT-P4) ─────────────────────────────────');
    out.writeln('  materializing state after step $step by verified replay…');

    final MachineCheckpoint checkpoint;
    try {
      final machine = await session.materializedMachine();
      checkpoint = MachineCheckpoint.capture(
        runtime: machine.runtime,
        vm: machine.host,
        program: session.program,
      );
    } on ReplayDivergence catch (e) {
      err.writeln('✗ $e');
      err.writeln('  The recording no longer matches this toolchain — cannot '
          'seed a live resume from a diverged state.');
      return 1;
    } on StateError catch (e) {
      err.writeln('✗ ${e.message}');
      return 1;
    }

    final resolved = await resolveBackendModel(results: context.parsedResults, context: context, err: err);
    final model = resolved.model;
    out.writeln('  prefix  : ${step + 1} step(s), '
        '${session.materializedModelCalls} taped model call(s), '
        '${checkpoint.budgetConsumedTokens} tokens already accounted');
    out.writeln('  backend : ${model.modelName} (live from step ${step + 1})');

    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
    final runtime = await checkpoint.restoreRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    ExecutionTracer? tracer;
    if (context.parsedResults['trace'] as bool? ?? false) {
      tracer = ExecutionTracer(runtime, sink: out.writeln)..attach();
    }

    var state = await checkpoint.resumeWith(runtime);

    // HITL gates reached by the live suffix answer interactively, the same
    // stdin contract `vaster resume` uses when no re-park dir is given.
    while (state.status == RuntimeStatus.pausedForHuman) {
      final request = runtime.pendingHumanRequest;
      if (request == null) break;
      out.writeln('\n── HUMAN INTERACTION REQUIRED ──────────────────────────');
      out.writeln('  ${request.prompt}');
      if (request.options.isNotEmpty) {
        out.writeln('  options: ${request.options.join(' / ')}');
      }
      out.write('> ');
      final answer = stdin.readLineSync()?.trim();
      if (answer == null || answer.isEmpty) {
        err.writeln('No input available — leaving program paused.');
        tracer?.detach();
        await vm.shutdown();
        await resolved.dispose();
        return 2;
      }
      final reply = switch (answer.toLowerCase()) {
        'yes' || 'y' || 'approve' => HumanInteractionResponse.approve(requestId: request.requestId),
        'no' ||
        'n' ||
        'reject' =>
          HumanInteractionResponse.reject(requestId: request.requestId, reason: 'Rejected by user.'),
        _ => HumanInteractionResponse.answer(requestId: request.requestId, answerText: answer),
      };
      state = await runtime.resumeWithHumanResponse(reply);
    }

    tracer?.detach();

    out.writeln('\n── LIVE RESUME COMPLETE ────────────────────────────────');
    out.writeln('  status : ${state.status.name}');
    out.writeln('  tokens : ${runtime.budget.consumedTokens} total '
        '(${runtime.budget.consumedTokens - checkpoint.budgetConsumedTokens} '
        'live this resume)');
    if (runtime.budget.consumedCost > 0) {
      out.writeln('  cost   : \$${runtime.budget.consumedCost.toStringAsFixed(6)}');
    }
    final resultRegister = session.program.resultBinding;
    if (resultRegister != null && state.registers.containsKey(resultRegister)) {
      out.writeln('  output :');
      out.writeln('${state.registers[resultRegister]}');
    }
    if (state.status == RuntimeStatus.error) {
      err.writeln('\n${state.errorDetails}');
    }

    await vm.shutdown();
    await resolved.dispose();
    return state.status == RuntimeStatus.halted ? 0 : 1;
  }

  /// Executes one debugger command; returns false to quit.
  Future<bool> _dispatch(String line, DebugSession session, StringSink out, StringSink err) async {
    final parts = line.split(RegExp(r'\s+'));
    final cmd = parts.first;
    final arg = parts.length > 1 ? parts.sublist(1).join(' ') : null;

    try {
      switch (cmd) {
        case 'q' || 'quit' || 'exit':
          return false;
        case 'h' || 'help':
          out.writeln(_help);
        case 's' || 'step':
          session.stepForward(int.tryParse(arg ?? '') ?? 1);
          _printFrame(session, out);
        case 'b' || 'back':
          session.stepBack(int.tryParse(arg ?? '') ?? 1);
          _printFrame(session, out);
        case 'seek':
          session.seek(int.tryParse(arg ?? '') ?? 0);
          _printFrame(session, out);
        case 'run-to':
          final pc = int.tryParse(arg ?? '') ?? -1;
          final steps = session.stepsAtPc(pc);
          final next = steps.where((s) => s > session.cursor).firstOrNull ?? steps.firstOrNull;
          if (next == null) {
            err.writeln('PC $pc never executed in this recording.');
          } else {
            session.seek(next);
            _printFrame(session, out);
          }
        case 'l' || 'list':
          _printListing(session, out);
        case 'regs':
          final registers = session.currentFrame.registers;
          if (registers.isEmpty) out.writeln('  (no registers yet)');
          for (final entry in registers.entries) {
            out.writeln('  ${entry.key} = ${_truncate('${entry.value}')}');
          }
        case 'diff':
          final delta = session.diffFromPrevious();
          if (delta.changes.isEmpty) out.writeln('  (no register changes)');
          for (final change in delta.changes) {
            out.writeln('  $change');
          }
        case 'where':
          final stack = session.currentFrame.callStack;
          if (stack.isEmpty) out.writeln('  (top level)');
          for (final frame in stack.reversed) {
            out.writeln('  ${frame.functionName} → returns to PC:${frame.returnPc}');
          }
        case 'frames':
          final pc = int.tryParse(arg ?? '') ?? session.currentFrame.pc;
          final steps = session.stepsAtPc(pc);
          out.writeln('  PC $pc executed at step(s): '
              '${steps.isEmpty ? '(never)' : steps.join(', ')}');
        case 'tape':
          for (var i = 0; i < session.tapeEntries.length; i++) {
            final entry = session.tapeEntries[i];
            final usage = ModelResponse.fromJson(entry.responseJson).usage;
            out.writeln('  [$i] "${entry.requestPreview}" → '
                '${usage.totalTokenCount} tok'
                '${usage.costUsd != null ? ' \$${usage.costUsd!.toStringAsFixed(4)}' : ''}');
          }
        case 'info':
          out.writeln('  program : ${session.program.programName}');
          out.writeln('  result  : '
              '${session.program.resultBinding ?? '(none declared)'}');
          out.writeln('  classes : '
              '${session.program.contextClasses != null ? 'program-declared' : 'standard table'}');
          for (final warning in session.warnings) {
            out.writeln('  ⚠ $warning');
          }
        case 'result':
          out.writeln('${session.declaredResult}');
        case 'checkpoint':
          if (arg == null) {
            err.writeln('Usage: checkpoint <file.ckpt.json>');
          } else {
            final machine = await session.materializedMachine();
            final checkpoint = MachineCheckpoint.capture(
              runtime: machine.runtime,
              vm: machine.host,
              program: session.program,
            );
            File(arg)
              ..parent.createSync(recursive: true)
              ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(checkpoint.toJson()));
            out.writeln('  checkpoint at step ${session.cursor} → $arg');
            out.writeln('  resume: vaster resume $arg --backend <backend>');
          }
        case 'vfs':
          final listing = await session.listVfs(arg ?? '/');
          if (listing.isEmpty) out.writeln('  (empty)');
          for (final descriptor in listing) {
            out.writeln('  ${descriptor.path}  (${descriptor.sizeBytes} bytes)');
          }
        case 'cat':
          if (arg == null) {
            err.writeln('Usage: cat <vfs path>');
          } else {
            out.writeln(await session.readVfs(arg));
          }
        case 'ctx':
          final ctx = await session.contextState();
          out.writeln('  segment table: '
              '${ctx.classTable.inBandOrder.map((c) => c.name).join(' < ')}');
          if (ctx.regions.isEmpty) out.writeln('  (heap empty)');
          for (final region in ctx.regions) {
            out.writeln('  [${region.classId ?? 'general'}] ${region.id} '
                '~${region.estimatedTokens} tok'
                '${region.isPinned ? ' PIN' : ''}');
          }
          final usage = ctx.lastCompiled?.classUsage;
          if (usage != null && usage.isNotEmpty) {
            out.writeln('  last compile:');
            for (final entry in usage.entries) {
              out.writeln('    ${entry.key.padRight(12)} ${entry.value}');
            }
          }
        default:
          err.writeln('Unknown command "$cmd" — try help.');
      }
    } on ReplayDivergence catch (e) {
      err.writeln('✗ $e');
      err.writeln('  The recording no longer matches this toolchain — '
          'journal views remain exact; materialized views are unavailable.');
    } on StateError catch (e) {
      err.writeln('✗ ${e.message}');
    } catch (e) {
      err.writeln('✗ $e');
    }
    return true;
  }

  void _printFrame(DebugSession session, StringSink out) {
    final frame = session.currentFrame;
    const dis = VasterDisassembler();
    out.writeln('step ${frame.stepIndex}/${session.length - 1}  '
        '${dis.formatLine(frame.pc, frame.instruction)}');
  }

  void _printListing(DebugSession session, StringSink out) {
    const dis = VasterDisassembler();
    final pc = session.currentFrame.pc;
    final instructions = session.program.instructions;
    final from = (pc - 4).clamp(0, instructions.length - 1);
    final to = (pc + 4).clamp(0, instructions.length - 1);
    for (var i = from; i <= to; i++) {
      final cursor = i == pc ? '→' : ' ';
      final executed = session.stepsAtPc(i).isNotEmpty ? ' ' : '·';
      out.writeln(' $cursor$executed ${dis.formatLine(i, instructions[i])}');
    }
    out.writeln('   (· = never executed in this recording)');
  }

  static String _truncate(String value, [int max = 120]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';

  static const _help = '''
  s [n] / b [n]   step forward / back n steps (default 1)
  seek N          jump to step N
  run-to PC       jump to the next step that executed PC
  l               listing around the current PC (→ cursor, · never ran)
  regs / diff     registers at cursor / changes vs previous step
  where           call stack at cursor
  frames [PC]     steps that executed PC (loop iterations)
  vfs [path]      VFS listing at cursor (replay-materialized)
  cat <path>      file content at cursor (replay-materialized)
  ctx             context heap + segment usage at cursor (materialized)
  tape            recorded model calls with usage/cost
  info / result   program header / declared result value
  checkpoint <f>  export a durable checkpoint of the state at the cursor
                  (resume later: vaster resume <f> --backend <backend>)
  q               quit''';
}
