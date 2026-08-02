import 'dart:convert';
import 'dart:io';

import '../vaster_command.dart';

class RunCommand extends VasterCommand {
  @override
  String get name => 'run';

  @override
  List<String> get aliases => const [];

  @override
  String get description => 'Compiles and executes a Vaster AST pipeline script.';

  @override
  Future<int> execute(CommandContext context) async {
    final args = context.parsedResults.rest;
    final out = context.stdoutSink;
    final err = context.stderrSink;

    if (args.isEmpty) {
      err.writeln('Error: Missing pipeline script path.');
      err.writeln('Usage: vaster run <script.dart>');
      return 1;
    }

    final targetPath = args.first;
    final file = File(targetPath);

    if (!file.existsSync()) {
      err.writeln('Error: Pipeline script file not found at $targetPath');
      return 1;
    }

    out.writeln('======================================================================');
    out.writeln('  VASTER PIPELINE EXECUTION ENGINE                                     ');
    out.writeln('  Executing: $targetPath                                               ');
    out.writeln('======================================================================\n');

    final process = await Process.start(
      'dart',
      ['run', targetPath],
      workingDirectory: context.workingDirectory,
    );

    final stdoutSub = process.stdout.transform(utf8.decoder).listen((data) => out.write(data));
    final stderrSub = process.stderr.transform(utf8.decoder).listen((data) => err.write(data));

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    return exitCode;
  }
}
