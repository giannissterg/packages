import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  print('=== Vaster ISA Bytecode Serialization Example ===');

  const program = VasterProgram(
    programName: 'workflow_compiler_output',
    instructions: [
      MountFsOp(mountPrefix: '/workspace'),
      WriteFileOp(vfsPath: '/workspace/main.dart', content: 'void main() => print("Hello");'),
      PromptOp(promptText: 'Analyze /workspace/main.dart', outputVar: 'analysis'),
      HaltOp(),
    ],
  );

  final json = program.toJson();
  print('Serialized Program JSON:');
  print(json);
}
