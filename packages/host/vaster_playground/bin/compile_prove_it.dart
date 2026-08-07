import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Compiles the "prove it" workflow: a genuinely useful pipeline — drafting
/// the v0.4.0 release announcement — that exercises the whole promise on a
/// real backend: pinned knowledge, a program-declared budget, two model
/// turns in one session, a human approval gate (durable parking point), and
/// a disk-mounted artifact so the approved output survives every process
/// involved.
void main(List<String> args) {
  final outDir = args.isNotEmpty ? args.first : 'artifacts/prove_it';

  const pipeline = Pipeline(
    name: 'release_scribe',
    mounts: [
      StorageMount(
        mountPrefix: '/workspace',
        type: StorageMountType.disk,
        diskPath: 'artifacts/prove_it/workspace',
      ),
    ],
    inputs: {Binding('project'): 'Vaster', Binding('version'): 'v0.4.0'},
    result: Binding('outcome'),
    children: [
      BudgetScope(
        maxTokens: 60000,
        maxCost: 2.0,
        child: Knowledge(
          label: 'release facts',
          pinned: true,
          text: Template.text(
            'Vaster is an LLM virtual machine for Dart: declarative '
            'pipelines compile to serializable bytecode executed by a '
            'runtime with real token/cost metering. v0.4.0 ships: '
            '(1) durable execution — a running pipeline can suspend to a '
            'self-contained JSON checkpoint at a human-approval gate, the '
            'process can die, and `vaster resume` completes it in a fresh '
            'VM, meters continuing where they stood; (2) a machine-state '
            'architecture where every piece of runtime state lives in a '
            'snapshotable component, enforced by a checkpoint-anywhere '
            'test; (3) `vaster check` — static verification: every '
            'register read proven dominated by a write, a worst-case '
            'dollar bound from loop analysis and pricing tables, and '
            'policy proofs that catch forbidden file writes before '
            'execution; (4) actor-semantics agents (one task at a time '
            'per agent) and sealed failure types throughout. 614 tests.',
          ),
          child: Sequence([
            Prompt(
              Template.text(
                'Draft a release announcement for \${project} \${version} '
                'using ONLY the facts in your context. Structure: one '
                'opening paragraph on what the release means, then a '
                'short bulleted list of the four highlights, then one '
                'closing sentence. Under 250 words. No hype adjectives.',
              ),
              output: Binding('draft'),
            ),
            Prompt(
              Template.text(
                'Here is your draft:\n\${draft}\n\nTighten it: cut '
                'anything not grounded in the stated facts, prefer '
                'concrete nouns over marketing language, keep it under '
                '200 words. Reply with the final text only.',
              ),
              output: Binding('final_draft'),
            ),
            ApprovalGate(
              requestId: 'publish_gate',
              prompt: Template.text(
                'Publish this announcement for \${project} '
                '\${version}?\n\n\${final_draft}',
              ),
              onApprove: [
                WriteFile(
                  path: Template.text('/workspace/RELEASE_NOTES.md'),
                  content: Template.text('\${final_draft}'),
                ),
                Inputs({Binding('outcome'): 'published'}),
              ],
              onReject: [
                Inputs({Binding('outcome'): 'withheld'}),
              ],
            ),
          ]),
        ),
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  Directory(outDir).createSync(recursive: true);
  final path = '$outDir/release_scribe.vbc';
  File(path).writeAsBytesSync(program.toBytes());
  stdout.writeln(
    'compiled ${program.instructions.length} instructions → '
    '$path (resultBinding: ${program.resultBinding})',
  );
}
