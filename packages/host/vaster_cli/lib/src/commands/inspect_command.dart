import 'dart:convert';
import 'dart:io';

import '../vaster_command.dart';

class InspectCommand extends VasterCommand {
  @override
  String get name => 'inspect';

  @override
  List<String> get aliases => const ['cat'];

  @override
  String get description => 'Inspects and pretty-prints a serialized VasterContinuation snapshot file.';

  @override
  Future<int> execute(CommandContext context) async {
    final args = context.parsedResults.rest;
    final out = context.stdoutSink;
    final err = context.stderrSink;

    if (args.isEmpty) {
      err.writeln('Error: Missing continuation snapshot file path.');
      err.writeln('Usage: vaster inspect <snapshot.json>');
      return 1;
    }

    final path = args.first;
    final file = File(path);

    if (!file.existsSync()) {
      err.writeln('Error: Snapshot file not found at $path');
      return 1;
    }

    out.writeln('======================================================================');
    out.writeln('  VASTER CONTINUATION SNAPSHOT INSPECTOR                               ');
    out.writeln('  Target Snapshot: $path                                               ');
    out.writeln('======================================================================\n');

    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;

    out.writeln('┌─ SNAPSHOT METADATA ───────────────────────────────────────────┐');
    out.writeln('  ✓ Continuation ID    : ${json['continuationId']}');
    out.writeln('  ✓ Program Name       : ${json['programName']}');
    out.writeln('  ✓ Resume PC Offset   : ${json['resumePc']}');
    out.writeln('  ✓ Active Model       : ${json['activeModelDescriptor']}');
    out.writeln('  ✓ Suspended At Timestamp: ${json['suspendedAt']}');

    final pending = json['pendingRequest'] as Map<String, dynamic>?;
    if (pending != null) {
      out.writeln('\n┌─ PENDING HUMAN REQUEST (HITL) ────────────────────────────────┐');
      out.writeln('  ✓ Request ID         : ${pending['requestId']}');
      out.writeln('  ✓ Prompt             : "${pending['prompt']}"');
      out.writeln('  ✓ Allowed Actions    : ${pending['allowedActions']}');
    }

    final registers = json['registers'] as Map<String, dynamic>? ?? {};
    out.writeln('\n┌─ REGISTER DUMP (${registers.length} registers) ─────────────────────────────┐');
    for (final entry in registers.entries) {
      final valStr = entry.value.toString();
      final preview = valStr.length > 60 ? '${valStr.substring(0, 60)}...' : valStr;
      out.writeln('  [${entry.key.padRight(20)}] = $preview');
    }

    out.writeln('\n======================================================================');
    out.writeln('  CONTINUATION INSPECTION COMPLETE                                     ');
    out.writeln('======================================================================');
    return 0;
  }
}
