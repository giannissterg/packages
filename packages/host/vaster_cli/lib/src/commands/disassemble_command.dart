import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

import '../vaster_command.dart';

class DisassembleCommand extends VasterCommand {
  @override
  String get name => 'disassemble';

  @override
  List<String> get aliases => const ['dis'];

  @override
  String get description => 'Compiles a Vaster AST pipeline script and displays ISA bytecode disassembly.';

  @override
  void configureArgs(ArgParser parser) {
    parser.addFlag(
      'stats-only',
      abbr: 's',
      help: 'Output instruction breakdown statistics only without full listing.',
      negatable: false,
    );
  }

  @override
  Future<int> execute(CommandContext context) async {
    final args = context.parsedResults.rest;
    final out = context.stdoutSink;
    final err = context.stderrSink;

    if (args.isEmpty) {
      err.writeln('Error: Missing pipeline script path.');
      err.writeln('Usage: vaster disassemble <script.dart> [--stats-only]');
      return 1;
    }

    final targetPath = args.first;
    final file = File(targetPath);

    if (!file.existsSync()) {
      err.writeln('Error: Pipeline script file not found at $targetPath');
      return 1;
    }

    out.writeln('======================================================================');
    out.writeln('  VASTER ISA DISASSEMBLER                                              ');
    out.writeln('  Target Script: $targetPath                                           ');
    out.writeln('======================================================================\n');

    // Binary bytecode: disassemble directly, no script execution.
    if (targetPath.endsWith('.vbc')) {
      try {
        final listing = const VasterDisassembler().disassembleBytes(
          file.readAsBytesSync(),
          options: DisassemblerOptions(
            showStats: true,
          ),
        );
        out.writeln(listing);
        return 0;
      } on VbcDecodeException catch (e) {
        err.writeln('Error: $e');
        return 1;
      }
    }

    // JSON program payloads: disassemble directly as well.
    if (targetPath.endsWith('.vaster.json') || targetPath.endsWith('.json')) {
      final listing = const VasterDisassembler()
          .disassembleJson(file.readAsStringSync());
      out.writeln(listing);
      return 0;
    }

    final result = await Process.run(
      'dart',
      ['run', targetPath],
      workingDirectory: context.workingDirectory,
    );

    if (result.exitCode != 0) {
      err.writeln('Error compiling pipeline script:');
      err.writeln(result.stderr);
      return result.exitCode;
    }

    out.writeln(result.stdout);
    return 0;
  }
}
