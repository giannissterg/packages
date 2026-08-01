import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_dis/vaster_dis.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'input',
      abbr: 'i',
      help: 'Path to .vaster JSON bytecode file to disassemble.',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Optional output file path to write disassembly text.',
    )
    ..addFlag(
      'stats',
      abbr: 's',
      defaultsTo: true,
      help: 'Include instruction opcode statistics in disassembly output.',
    )
    ..addFlag(
      'json',
      abbr: 'j',
      defaultsTo: false,
      help: 'Output formatted JSON payload instead of text disassembly.',
    )
    ..addFlag(
      'no-addresses',
      defaultsTo: false,
      help: 'Hide Program Counter (PC) addresses in disassembly output.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage information.',
    );

  try {
    final results = parser.parse(arguments);

    if (results['help'] as bool) {
      _printUsage(parser);
      return;
    }

    String? inputFilePath = results['input'] as String?;
    if (inputFilePath == null && results.rest.isNotEmpty) {
      inputFilePath = results.rest.first;
    }

    if (inputFilePath == null || inputFilePath.isEmpty) {
      stderr.writeln('Error: No input .vaster bytecode file specified.\n');
      _printUsage(parser);
      exitCode = 64; // EX_USAGE
      return;
    }

    final file = File(inputFilePath);
    if (!await file.exists()) {
      stderr.writeln('Error: File not found at "$inputFilePath"');
      exitCode = 66; // EX_NOINPUT
      return;
    }

    final jsonContent = await file.readAsString();

    if (results['json'] as bool) {
      final decoded = jsonDecode(jsonContent);
      final prettyJson = const JsonEncoder.withIndent('  ').convert(decoded);
      stdout.writeln(prettyJson);
      return;
    }

    const disassembler = VasterDisassembler();
    final options = DisassemblerOptions(
      showStats: results['stats'] as bool,
      showAddresses: !(results['no-addresses'] as bool),
    );

    final disassemblyText = disassembler.disassembleJson(
      jsonContent,
      options: options,
    );

    final outputPath = results['output'] as String?;
    if (outputPath != null && outputPath.isNotEmpty) {
      await File(outputPath).writeAsString(disassemblyText);
      stdout.writeln('✓ Disassembly written to $outputPath');
    } else {
      stdout.writeln(disassemblyText);
    }
  } catch (e) {
    stderr.writeln('Disassembler Error: $e');
    exitCode = 1;
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Usage: vaster-dis [options] <file.vaster>\n');
  stdout.writeln('CLI disassembler tool for inspecting .vaster bytecode files.\n');
  stdout.writeln(parser.usage);
}
