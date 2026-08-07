import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Compiles the replay-demo workflow: four chained model turns over a
/// pinned knowledge prefix, no gate — recordable end to end
/// (`vaster run … --record`), then regression-tested forever with
/// `vaster replay <envelope> --diff` at zero tokens. Four calls also
/// clears the calibration fitter's sample floor, so a llama recording
/// of this program doubles as a prompt-side calibration fixture.
///
///     dart run vaster_playground:compile_replay_demo
void main(List<String> args) {
  final outDir = args.isNotEmpty ? args.first : 'artifacts/replay_demo';

  const pipeline = Pipeline(
    name: 'story_lines',
    inputs: {Binding('hero'): 'Bo the dog'},
    result: Binding('line4'),
    children: [
      Knowledge(
        label: 'story facts',
        pinned: true,
        text: Template.text(
          'Story facts: Bo is a small brown dog who lives at the edge of '
          'a pine forest with a lighthouse keeper named Ana. Bo fears '
          'thunder but loves the sea.',
        ),
        child: Sequence([
          Prompt(
            Template.text(
              'Using the story facts, write the opening line '
              'of a story about \${hero}.',
            ),
            output: Binding('line1'),
          ),
          Prompt(Template.text('Continue with one line after:\n\${line1}'), output: Binding('line2')),
          Prompt(Template.text('Continue with one line after:\n\${line2}'), output: Binding('line3')),
          Prompt(Template.text('Write the closing line after:\n\${line3}'), output: Binding('line4')),
        ]),
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  Directory(outDir).createSync(recursive: true);
  final path = '$outDir/story_lines.vbc';
  File(path).writeAsBytesSync(program.toBytes());
  stdout.writeln(
    'compiled ${program.instructions.length} instructions → '
    '$path (resultBinding: ${program.resultBinding})',
  );
}
