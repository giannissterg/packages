import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import '../vaster_command.dart';

/// Time-travel debugger over a recorded execution envelope.
///
/// Journal views (registers, deltas, call stack, listing) are instant and
/// pure; `vfs`/`cat`/`ctx` materialize state at the cursor by verified tape
/// replay (see `DebugSession`).
class DebugCommand extends VasterCommand {
  @override
  String get name => 'debug';

  @override
  String get description =>
      'Time-travel debugger over a recorded envelope: step forward/back '
      'through a run, inspecting registers, VFS, and context at any step.';

  @override
  void configureArgs(ArgParser parser) {
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
          : VasterProgram.fromJson(
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    }

    final DebugSession session;
    try {
      session = DebugSession.load(DebugEnvelope.parse(
        envelopeFile.readAsStringSync(),
        programOverride: programOverride,
      ));
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

    final script = context.parsedResults['script'] as String?;
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

  /// Executes one debugger command; returns false to quit.
  Future<bool> _dispatch(String line, DebugSession session, StringSink out,
      StringSink err) async {
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
          final next = steps.where((s) => s > session.cursor).firstOrNull ??
              steps.firstOrNull;
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
            out.writeln(
                '  ${frame.functionName} → returns to PC:${frame.returnPc}');
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
        case 'vfs':
          final listing = await session.listVfs(arg ?? '/');
          if (listing.isEmpty) out.writeln('  (empty)');
          for (final descriptor in listing) {
            out.writeln(
                '  ${descriptor.path}  (${descriptor.sizeBytes} bytes)');
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
  q               quit''';
}
