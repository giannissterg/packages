import 'package:args/args.dart';

/// Context passed to a [VasterCommand] execution invocation containing parsed command-line
/// options, working directory paths, environment state, and standard output/error sinks.
class CommandContext {
  final List<String> rawArguments;
  final ArgResults parsedResults;
  final String workingDirectory;
  final String socketPath;
  final StringSink stdoutSink;
  final StringSink stderrSink;

  const CommandContext({
    required this.rawArguments,
    required this.parsedResults,
    required this.workingDirectory,
    required this.socketPath,
    required this.stdoutSink,
    required this.stderrSink,
  });
}

/// Abstract interface contract implemented by all Vaster CLI subcommands.
abstract class VasterCommand {
  /// Unique name used to invoke this subcommand (e.g. "disassemble", "run", "serve").
  String get name;

  /// Optional aliases for this command (e.g. "dis" for "disassemble").
  List<String> get aliases => const [];

  /// Human-readable description displayed in `vaster --help` output.
  String get description;

  /// Configures command-specific flags and options on the provided [ArgParser].
  ArgParser configureArgs(ArgParser parser) => parser;

  /// Executes the subcommand logic using the provided [CommandContext].
  ///
  /// Returns an exit code integer (`0` for success, non-zero for failure).
  Future<int> execute(CommandContext context);
}
