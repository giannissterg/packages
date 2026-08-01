import 'package:test/test.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  group('VasterInstruction & VasterProgram ISA', () {
    test('JSON roundtrip serialization of VasterInstruction opcodes', () {
      const promptOp = PromptOp(promptText: 'Hello ISA', outputVar: 'r0');
      const mountOp = MountFsOp(mountPrefix: '/workspace');
      const setRegOp = SetRegisterOp(registerName: 'counter', value: 42);
      const jumpIfOp = JumpIfOp(targetPc: 5, conditionVar: 'counter');
      const haltOp = HaltOp();

      final program = VasterProgram(
        programName: 'test_program',
        instructions: [promptOp, mountOp, setRegOp, jumpIfOp, haltOp],
      );

      final json = program.toJson();
      final restored = VasterProgram.fromJson(json);

      expect(restored.programName, equals('test_program'));
      expect(restored.instructions, hasLength(5));
      expect(restored.instructions[2], isA<SetRegisterOp>());
      expect((restored.instructions[2] as SetRegisterOp).value, equals(42));
      expect(restored.instructions[3], isA<JumpIfOp>());
      expect((restored.instructions[3] as JumpIfOp).targetPc, equals(5));
      expect(restored.instructions.last, isA<HaltOp>());
    });
  });
}
