import 'package:test/test.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  group('Context management ISA ops — JSON round-trip', () {
    test('AddContextOp round-trips with all fields', () {
      const op = AddContextOp(
        regionId: 'notes',
        label: 'design notes',
        text: 'the content',
        priority: 'high',
        lifetime: 'step',
        compressibility: 'summarize',
        pinned: true,
      );
      final restored =
          VasterInstruction.fromJson(op.toJson()) as AddContextOp;
      expect(restored.regionId, equals('notes'));
      expect(restored.text, equals('the content'));
      expect(restored.priority, equals('high'));
      expect(restored.lifetime, equals('step'));
      expect(restored.compressibility, equals('summarize'));
      expect(restored.pinned, isTrue);
      expect(restored.sourceVar, isNull);
    });

    test('AddContextOp with sourceVar', () {
      const op = AddContextOp(regionId: 'r', label: 'l', sourceVar: 'reg0');
      final restored =
          VasterInstruction.fromJson(op.toJson()) as AddContextOp;
      expect(restored.sourceVar, equals('reg0'));
    });

    test('EvictContextOp / UnpinContextOp round-trip', () {
      const evict = EvictContextOp(regionId: 'x', force: true);
      final restoredEvict =
          VasterInstruction.fromJson(evict.toJson()) as EvictContextOp;
      expect(restoredEvict.force, isTrue);

      const unpin = UnpinContextOp(regionId: 'y');
      expect(
          (VasterInstruction.fromJson(unpin.toJson()) as UnpinContextOp)
              .regionId,
          equals('y'));
    });

    test('SetContextPolicyOp only carries provided fields', () {
      const op = SetContextPolicyOp(regionId: 'z', pinned: false, utility: 0.5);
      final json = op.toJson();
      expect(json.containsKey('priority'), isFalse);
      final restored =
          VasterInstruction.fromJson(json) as SetContextPolicyOp;
      expect(restored.pinned, isFalse);
      expect(restored.utility, equals(0.5));
      expect(restored.priority, isNull);
    });

    test('CompressContextOp round-trips nullable fields', () {
      const whole = CompressContextOp(outputVar: 'freed');
      final restoredWhole =
          VasterInstruction.fromJson(whole.toJson()) as CompressContextOp;
      expect(restoredWhole.regionId, isNull);
      expect(restoredWhole.outputVar, equals('freed'));

      const targeted = CompressContextOp(regionId: 'doc', targetTokens: 128);
      final restoredTargeted =
          VasterInstruction.fromJson(targeted.toJson()) as CompressContextOp;
      expect(restoredTargeted.regionId, equals('doc'));
      expect(restoredTargeted.targetTokens, equals(128));
    });
  });
}
