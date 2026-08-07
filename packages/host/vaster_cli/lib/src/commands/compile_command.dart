import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

import '../vaster_command.dart';

/// Compiles a serialized VasterProgram into a distributable artifact.
///
/// Bridges the compile-once-run-many toolchain: a program authored as JSON
/// (or an existing `.vbc`) is statically analyzed with [ProgramAnalyzer] and
/// emitted as VBC binary (default) or canonical JSON (`--json`). Error-level
/// diagnostics abort the build; `--check` analyzes without writing anything.
///
/// AST pipeline scripts (`.dart`) compile through the library API — run them
/// with `vaster run script.dart` or have the script emit its own artifact.
class CompileCommand extends VasterCommand {
  @override
  String get name => 'compile';

  @override
  List<String> get aliases => const ['build'];

  @override
  String get description =>
      'Analyzes a VasterProgram (.json/.vbc) and emits a .vbc binary '
      '(or canonical JSON with --json).';

  @override
  ArgParser configureArgs(ArgParser parser) {
    parser.addOption(
      'output',
      abbr: 'o',
      help: 'Artifact path (default: input path with the target extension).',
    );
    parser.addFlag(
      'json',
      help: 'Emit canonical program JSON instead of VBC binary.',
      negatable: false,
    );
    parser.addFlag(
      'check',
      abbr: 'c',
      help: 'Analyze only — print diagnostics, write no artifact.',
      negatable: false,
    );
    return parser;
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final rest = context.parsedResults.rest;

    if (rest.isEmpty) {
      err.writeln('Error: Missing program path.');
      err.writeln('Usage: vaster compile <program.json | program.vbc> '
          '[-o <artifact>] [--json] [--check]');
      return 1;
    }

    final inputPath = rest.first;
    final file = File(inputPath);
    if (!file.existsSync()) {
      err.writeln('Error: File not found at $inputPath');
      return 1;
    }

    // 1. Load the program from either serialization.
    final VasterProgram program;
    try {
      if (inputPath.endsWith('.vbc')) {
        program = VasterProgramBinary.fromBytes(file.readAsBytesSync());
      } else {
        program = VasterProgram.fromJson(
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      }
    } on VbcDecodeException catch (e) {
      err.writeln('Error: $e');
      return 1;
    } on FormatException catch (e) {
      err.writeln('Error: invalid program JSON: ${e.message}');
      return 1;
    }

    // 2. Static analysis — errors abort the build.
    final diagnostics = const ProgramAnalyzer().analyze(program);
    for (final d in diagnostics) {
      final location = d.pc != null ? ' @pc ${d.pc}' : '';
      final sink = d.severity == CompileSeverity.error ? err : out;
      sink.writeln('  [${d.severity.name}] ${d.code}$location: ${d.message}');
    }
    final errorCount =
        diagnostics.where((d) => d.severity == CompileSeverity.error).length;
    if (errorCount > 0) {
      err.writeln('Compilation failed: $errorCount error diagnostic(s).');
      return 1;
    }

    if (context.parsedResults['check'] as bool? ?? false) {
      out.writeln('OK: ${program.programName} '
          '(${program.instructions.length} instructions, '
          '${diagnostics.length} diagnostic(s)).');
      return 0;
    }

    // 3. Emit the artifact.
    final asJson = context.parsedResults['json'] as bool? ?? false;
    final extension = asJson ? '.json' : '.vbc';
    final outputPath = context.parsedResults['output'] as String? ??
        inputPath.replaceFirst(RegExp(r'\.(json|vbc)$'), extension);
    if (outputPath == inputPath) {
      err.writeln('Error: output would overwrite the input '
          '($inputPath) — pass -o with a different path.');
      return 1;
    }

    final outputFile = File(outputPath);
    final int bytesWritten;
    if (asJson) {
      final encoded =
          const JsonEncoder.withIndent('  ').convert(program.toJson());
      outputFile.writeAsStringSync('$encoded\n');
      bytesWritten = outputFile.lengthSync();
    } else {
      final bytes = program.toBytes();
      outputFile.writeAsBytesSync(bytes);
      bytesWritten = bytes.length;
    }

    out.writeln('Compiled ${program.programName}: '
        '${program.instructions.length} instructions → '
        '$outputPath ($bytesWritten bytes).');
    return 0;
  }
}
