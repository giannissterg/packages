import 'dart:io';

import 'package:args/args.dart';

import 'commands/audit_command.dart';
import 'commands/debug_command.dart';
import 'commands/compile_command.dart';
import 'commands/disassemble_command.dart';
import 'commands/doctor_command.dart';
import 'commands/inspect_command.dart';
import 'commands/check_command.dart';
import 'commands/resume_command.dart';
import 'commands/run_command.dart';
import 'commands/serve_command.dart';
import 'vaster_command.dart';

/// Main Vaster CLI command runner maintaining command registry and dispatching CLI subcommands.
class VasterCliRunner {
  final Map<String, VasterCommand> _commands = {};
  final ArgParser mainParser = ArgParser();

  VasterCliRunner({List<VasterCommand>? initialCommands}) {
    final commandsToRegister = initialCommands ??
        [
          RunCommand(),
          CheckCommand(),
          ResumeCommand(),
          CompileCommand(),
          AuditCommand(),
        DebugCommand(),
          DisassembleCommand(),
          ServeCommand(),
          InspectCommand(),
          DoctorCommand(),
        ];

    for (final cmd in commandsToRegister) {
      registerCommand(cmd);
    }
  }

  /// Registers a [VasterCommand] in the runner registry.
  void registerCommand(VasterCommand command) {
    _commands[command.name] = command;
    for (final alias in command.aliases) {
      _commands[alias] = command;
    }

    final subParser = mainParser.addCommand(command.name);
    command.configureArgs(subParser);
    for (final alias in command.aliases) {
      mainParser.addCommand(alias, subParser);
    }
  }

  /// Evaluates CLI arguments and dispatches execution to the matching [VasterCommand].
  Future<int> run(
    List<String> arguments, {
    StringSink? stdoutSink,
    StringSink? stderrSink,
  }) async {
    final out = stdoutSink ?? stdout;
    final err = stderrSink ?? stderr;

    if (arguments.isEmpty || arguments.contains('-h') || arguments.contains('--help')) {
      _printUsage(out);
      return 0;
    }

    final commandName = arguments.first;
    final command = _commands[commandName];

    if (command == null) {
      err.writeln('Error: Unknown Vaster command "$commandName"\n');
      _printUsage(err);
      return 1;
    }

    final commandArgs = arguments.sublist(1);
    final subParser = ArgParser();
    command.configureArgs(subParser);

    ArgResults parsedResults;
    try {
      parsedResults = subParser.parse(commandArgs);
    } catch (e) {
      err.writeln('Error parsing arguments for "$commandName": $e');
      return 1;
    }

    final homeDir = Platform.environment['HOME'] ?? '';
    final defaultSocket = '$homeDir/.gemini/antigravity/vaster_model.sock';

    final context = CommandContext(
      rawArguments: commandArgs,
      parsedResults: parsedResults,
      workingDirectory: Directory.current.path,
      socketPath: defaultSocket,
      stdoutSink: out,
      stderrSink: err,
    );

    return await command.execute(context);
  }

  void _printUsage(StringSink sink) {
    sink.writeln('======================================================================');
    sink.writeln('  VASTER LLM VIRTUAL MACHINE — OFFICIAL CLI                            ');
    sink.writeln('======================================================================\n');
    sink.writeln('Usage: vaster <command> [arguments]\n');
    sink.writeln('Available Subcommands:');

    final processed = <String>{};
    for (final cmd in _commands.values) {
      if (!processed.add(cmd.name)) continue;
      final aliasStr = cmd.aliases.isNotEmpty ? ' (aliases: ${cmd.aliases.join(', ')})' : '';
      sink.writeln('  ${cmd.name.padRight(16)}${cmd.description}$aliasStr');
    }

    sink.writeln('\nUse "vaster <command> --help" for command-specific options.');
  }
}
