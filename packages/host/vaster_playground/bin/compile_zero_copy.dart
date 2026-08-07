import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Compiles the zero-copy demo workflow (`docs/ZERO_COPY.md`): a pinned
/// knowledge prefix, a model turn, a human gate (durable parking point),
/// and a post-approval model turn. Run it on `--backend llama` with
/// `--checkpoint-dir`: parking prewarms the pinned region into a shared
/// KV frame, and the resuming process restores that state instead of
/// re-decoding the prefix — the resume that doesn't re-pay its prefix.
///
///     dart run vaster_playground:compile_zero_copy
void main(List<String> args) {
  final outDir = args.isNotEmpty ? args.first : 'artifacts/zero_copy';

  const pipeline = Pipeline(
    name: 'story_scribe',
    inputs: {Binding('hero'): 'Bo the dog'},
    result: Binding('ending'),
    children: [
      Knowledge(
        label: 'story facts',
        pinned: true,
        text: Template.text(
          'Story facts: Bo is a small brown dog who lives at the edge of '
          'a pine forest with a lighthouse keeper named Ana. Bo is afraid '
          'of thunder but loves the sea. Ana found Bo as a puppy in a '
          'rowboat after a storm. The lighthouse lamp is powered by an '
          'old brass dynamo that Bo can hear humming from the garden. '
          'Every autumn the geese pass over the forest and Bo howls '
          'goodbye to them.',
        ),
        child: Sequence([
          Prompt(
            Template.text(
              'Using the story facts, write the opening '
              'sentence of a story about \${hero}.',
            ),
            output: Binding('opening'),
          ),
          ApprovalGate(
            requestId: 'continue_gate',
            prompt: Template.text('Continue this story?\n\n\${opening}'),
            onApprove: [
              Prompt(
                Template.text(
                  'Using the story facts, write one closing '
                  'sentence for this story:\n\${opening}',
                ),
                output: Binding('ending'),
              ),
            ],
            onReject: [
              Inputs({Binding('ending'): '(story withheld)'}),
            ],
          ),
        ]),
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  Directory(outDir).createSync(recursive: true);
  final path = '$outDir/story_scribe.vbc';
  File(path).writeAsBytesSync(program.toBytes());
  stdout.writeln(
    'compiled ${program.instructions.length} instructions → '
    '$path (resultBinding: ${program.resultBinding})',
  );
}
