import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

import '../vaster_command.dart';

/// Static capability audit of a compiled program: what it can touch, who it
/// can call, where the model steers, where humans gate it, and its declared
/// resource ceilings — all enumerated before a single instruction runs.
class AuditCommand extends VasterCommand {
  @override
  String get name => 'audit';

  @override
  List<String> get aliases => const [];

  @override
  String get description =>
      'Enumerates a compiled program\'s capabilities (files, tools, models, '
      'sandboxes, decision surface, human gates, budgets) without running it.';

  @override
  void configureArgs(ArgParser parser) {
    parser.addFlag(
      'json',
      help: 'Emit the audit as machine-readable JSON.',
      negatable: false,
    );
    parser.addFlag(
      'diagnostics',
      abbr: 'd',
      help: 'Include ProgramAnalyzer diagnostics after the audit.',
      negatable: false,
    );
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final rest = context.parsedResults.rest;

    if (rest.isEmpty) {
      err.writeln('Error: Missing program path.');
      err.writeln('Usage: vaster audit <program.vbc | program.json> '
          '[--json] [--diagnostics]');
      return 1;
    }

    final file = File(rest.first);
    if (!file.existsSync()) {
      err.writeln('Error: File not found at ${rest.first}');
      return 1;
    }

    final VasterProgram program;
    try {
      program = rest.first.endsWith('.vbc')
          ? VasterProgramBinary.fromBytes(file.readAsBytesSync())
          : VasterProgram.fromJson(
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } on VbcDecodeException catch (e) {
      err.writeln('Error: $e');
      return 1;
    } on FormatException catch (e) {
      err.writeln('Error: invalid program JSON: ${e.message}');
      return 1;
    }

    final audit = CapabilityAudit.of(program);

    if (context.parsedResults['json'] as bool? ?? false) {
      out.writeln(const JsonEncoder.withIndent('  ').convert(audit.toJson()));
      return 0;
    }

    out.writeln(audit.toPrettyString());

    if (context.parsedResults['diagnostics'] as bool? ?? false) {
      final diagnostics = const ProgramAnalyzer().analyze(program);
      out.writeln('Diagnostics:');
      if (diagnostics.isEmpty) {
        out.writeln('  (clean)');
      } else {
        for (final d in diagnostics) {
          final location = d.pc != null ? ' @pc ${d.pc}' : '';
          out.writeln('  [${d.severity.name}] ${d.code}$location: ${d.message}');
        }
      }
    }
    return 0;
  }
}
