import 'package:test/test.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart' show ModelDescriptor;

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

    test('SelectModelOp roundtrips its fallback chain (REL-P3)', () {
      const op = SelectModelOp(
        descriptor: ModelDescriptor(provider: 'google_ai', modelId: 'gemini-2.5-pro'),
        fallbacks: [
          ModelDescriptor(provider: 'google_ai', modelId: 'gemini-2.5-flash'),
          ModelDescriptor(provider: 'fake', modelId: 'local'),
        ],
      );

      final restored = VasterInstruction.fromJson(op.toJson()) as SelectModelOp;
      expect(restored.descriptor.descriptorKey, 'google_ai:gemini-2.5-pro');
      expect(restored.fallbacks.map((f) => f.descriptorKey),
          ['google_ai:gemini-2.5-flash', 'fake:local']);
    });

    test('effect-scope ops roundtrip (REL-P4)', () {
      const ops = [
        PushEffectScopeOp(),
        MarkEffectRetryOp(),
        PopEffectScopeOp(),
      ];
      for (final op in ops) {
        final restored = VasterInstruction.fromJson(op.toJson());
        expect(restored.opcode, op.opcode);
        expect(restored.runtimeType, op.runtimeType);
      }
    });

    test('SelectModelOp without fallbacks stays byte-identical to pre-chain '
        'payloads', () {
      const op = SelectModelOp(
        descriptor: ModelDescriptor(provider: 'fake', modelId: 'default'),
      );
      // No `fallbacks` key at all — programs compiled before REL-P3 and
      // programs declaring no chain serialize the same bytes.
      expect(op.toJson().containsKey('fallbacks'), isFalse);
      final restored = VasterInstruction.fromJson(op.toJson()) as SelectModelOp;
      expect(restored.fallbacks, isEmpty);
    });
  });
}
