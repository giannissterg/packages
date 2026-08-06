import 'dart:convert';
import 'package:test/test.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_vm/vaster_vm.dart' show ModelDescriptor;

void main() {
  group('VasterDisassembler', () {
    const disassembler = VasterDisassembler();

    late VasterProgram sampleProgram;

    setUp(() {
      sampleProgram = const VasterProgram(
        programName: 'test_sample_program',
        instructions: [
          MountFsOp(mountPrefix: '/workspace'),
          WriteFileOp(vfsPath: '/workspace/main.dart', content: 'void main() {}'),
          PromptOp(promptText: 'Hello AI', outputVar: 'ai_resp'),
          JumpIfOp(targetPc: 4, conditionVar: 'ai_resp'),
          HaltOp(),
        ],
      );
    });

    test('disassembles VasterProgram into formatted text string', () {
      final disassembly = disassembler.disassemble(sampleProgram);

      expect(disassembly, contains('VASTER DISASSEMBLER — test_sample_program'));
      expect(disassembly, contains('[0000]  MOUNT_FS                 /workspace (memory)'));
      expect(disassembly, contains('[0002]  PROMPT                   "Hello AI" -> r[ai_resp]'));
      expect(disassembly, contains('[0003]  JUMP_IF                  if r[ai_resp] -> PC:0004 (L_0004)'));
      expect(disassembly, contains('[0004]  HALT                     --- HALT ---'));
      expect(disassembly, contains('INSTRUCTION STATISTICS'));
    });

    test('renders a SelectModelOp fallback chain in order (REL-P3)', () {
      const program = VasterProgram(
        programName: 'chained',
        instructions: [
          SelectModelOp(
            descriptor: ModelDescriptor(provider: 'google_ai', modelId: 'pro'),
            fallbacks: [
              ModelDescriptor(provider: 'google_ai', modelId: 'flash'),
              ModelDescriptor(provider: 'fake', modelId: 'local'),
            ],
          ),
          HaltOp(),
        ],
      );
      expect(disassembler.disassemble(program),
          contains('google_ai:pro → google_ai:flash → fake:local'));
    });

    test('annotates jump target labels correctly', () {
      final disassembly = disassembler.disassemble(sampleProgram);
      expect(disassembly, contains('L_0004:'));
    });

    test('disassembles JSON string payload correctly', () {
      final jsonMap = sampleProgram.toJson();
      final jsonString = jsonEncode(jsonMap);

      final disassembly = disassembler.disassembleJson(jsonString);

      expect(disassembly, contains('test_sample_program'));
      expect(disassembly, contains('MOUNT_FS'));
      expect(disassembly, contains('PROMPT'));
    });
  });
}
