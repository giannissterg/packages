import 'package:test/test.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  group('Control-flow op JSON round-trips', () {
    test('IncrementRegisterOp', () {
      const op = IncrementRegisterOp(registerName: 'counter', delta: 2.5);
      final decoded =
          VasterInstruction.fromJson(op.toJson()) as IncrementRegisterOp;
      expect(decoded.registerName, 'counter');
      expect(decoded.delta, 2.5);

      // Default delta survives the round-trip.
      const unit = IncrementRegisterOp(registerName: 'i');
      final decodedUnit =
          VasterInstruction.fromJson(unit.toJson()) as IncrementRegisterOp;
      expect(decodedUnit.delta, 1);
    });

    test('CompareRegisterOp with immediate value', () {
      const op = CompareRegisterOp(
        leftVar: 'i',
        operator: 'lt',
        rightValue: 10,
        targetVar: 'c',
      );
      final decoded =
          VasterInstruction.fromJson(op.toJson()) as CompareRegisterOp;
      expect(decoded.leftVar, 'i');
      expect(decoded.operator, 'lt');
      expect(decoded.rightVar, isNull);
      expect(decoded.rightValue, 10);
      expect(decoded.targetVar, 'c');
    });

    test('CompareRegisterOp with register operand', () {
      const op = CompareRegisterOp(
        leftVar: 'a',
        operator: 'eq',
        rightVar: 'b',
        targetVar: 'same',
      );
      final decoded =
          VasterInstruction.fromJson(op.toJson()) as CompareRegisterOp;
      expect(decoded.rightVar, 'b');
      expect(decoded.rightValue, isNull);
    });

    test('PushErrorHandlerOp', () {
      const op = PushErrorHandlerOp(targetPc: 42, errorVar: 'my_err');
      final decoded =
          VasterInstruction.fromJson(op.toJson()) as PushErrorHandlerOp;
      expect(decoded.targetPc, 42);
      expect(decoded.errorVar, 'my_err');

      const defaulted = PushErrorHandlerOp(targetPc: 7);
      final decodedDefault =
          VasterInstruction.fromJson(defaulted.toJson()) as PushErrorHandlerOp;
      expect(decodedDefault.errorVar, '__error__');
    });

    test('PopErrorHandlerOp', () {
      const op = PopErrorHandlerOp();
      expect(VasterInstruction.fromJson(op.toJson()), isA<PopErrorHandlerOp>());
    });

    test('new ops survive VBC binary encoding', () {
      const program = VasterProgram(
        programName: 'vbc_control_flow',
        instructions: [
          IncrementRegisterOp(registerName: 'i', delta: 3),
          CompareRegisterOp(
              leftVar: 'i', operator: 'ge', rightValue: 3, targetVar: 'done'),
          PushErrorHandlerOp(targetPc: 4, errorVar: 'e'),
          PopErrorHandlerOp(),
          HaltOp(),
        ],
      );
      final decoded = VasterProgramBinary.fromBytes(program.toBytes());
      expect(decoded.instructions, hasLength(5));
      expect(decoded.instructions[0], isA<IncrementRegisterOp>());
      expect((decoded.instructions[1] as CompareRegisterOp).operator, 'ge');
      expect((decoded.instructions[2] as PushErrorHandlerOp).targetPc, 4);
      expect(decoded.instructions[3], isA<PopErrorHandlerOp>());
    });
  });
}
