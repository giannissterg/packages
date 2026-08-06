import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Example 02 — compile a pipeline to an artifact the CLI can own.
///
/// Emits `artifacts/examples/triage_note.vbc`: a pipeline with a
/// program-declared budget, a human approval gate (a durable parking
/// point), and a disk-mounted output file. The point is everything you can
/// do with the artifact *without* this script: audit its capabilities,
/// statically check it, run it until it parks at the gate, kill the
/// process, and resume it from JSON. `docs/GETTING_STARTED.md` walks that
/// arc command by command.
///
///     dart run vaster_playground:example_02_ship_artifact
void main(List<String> args) {
  final outDir = args.isNotEmpty ? args.first : 'artifacts/examples';

  const pipeline = Pipeline(
    name: 'triage_note',
    mounts: [
      StorageMount(
        mountPrefix: '/workspace',
        type: StorageMountType.disk,
        diskPath: 'artifacts/examples/workspace',
      ),
    ],
    inputs: {
      Binding('report'):
          'Users on the EU cluster see stale dashboards for ~5 minutes '
          'after saving. Started after yesterday\'s cache rollout.',
    },
    result: Binding('outcome'),
    children: [
      BudgetScope(
        maxTokens: 20000,
        maxCost: 0.5,
        child: Sequence([
          Prompt(
            Template.text(
                'Triage this incident report. Reply with: one-line summary, '
                'suspected cause, severity (low/medium/high).\n\n\${report}'),
            output: Binding('triage'),
          ),
          ApprovalGate(
            requestId: 'file_ticket',
            prompt: Template.text(
                'File this triage note?\n\n\${triage}'),
            onApprove: [
              WriteFile(
                path: Template.text('/workspace/TRIAGE.md'),
                content: Template.text('\${triage}'),
              ),
              Inputs({Binding('outcome'): 'filed'}),
            ],
            onReject: [
              Inputs({Binding('outcome'): 'discarded'}),
            ],
          ),
        ]),
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  Directory(outDir).createSync(recursive: true);
  final path = '$outDir/triage_note.vbc';
  File(path).writeAsBytesSync(program.toBytes());

  stdout
    ..writeln('compiled ${program.instructions.length} instructions → $path')
    ..writeln('')
    ..writeln('Next, let the CLI own it:')
    ..writeln('  vaster audit $path')
    ..writeln('  vaster check $path --max-cost 0.5')
    ..writeln('  vaster run   $path --backend fake '
        '--checkpoint-dir artifacts/examples/ckpts   # parks at the gate, exit 3')
    ..writeln('  vaster resume artifacts/examples/ckpts/'
        'triage_note_file_ticket.ckpt.json --backend fake --respond approve');
}
