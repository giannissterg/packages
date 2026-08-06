import 'package:test/test.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

void main() {
  test('a compiled VBC program ships across processes via SharedMemoryFrame',
      () {
    const program = VasterProgram(programName: 'shipped', instructions: [
      SetRegisterOp(registerName: 'greeting', value: 'hello'),
      PromptOp(promptText: 'say hi', outputVar: 'r0'),
      ConcatRegisterOp(targetVar: '__output__', sourceVars: ['r0']),
      HaltOp(),
    ]);

    // Producer: encode and publish the program as a named physical frame.
    final name = 'vaster_prog_${DateTime.now().microsecondsSinceEpoch}';
    final producer = SharedMemoryFrame.create(name, program.toBytes(),
        meta: program.instructions.length);

    // Consumer (fresh attach by name — the cross-process path): map the
    // same physical pages and decode the program zero-copy.
    final consumer = SharedMemoryFrame.attach(name);
    expect(consumer.meta, equals(4), reason: 'instruction count in header');

    final shipped = VasterProgramBinary.fromBytes(consumer.bytes);
    expect(shipped.programName, equals('shipped'));
    expect(shipped.instructions.length, equals(4));
    expect(shipped.instructions[1], isA<PromptOp>());
    expect((shipped.instructions[1] as PromptOp).outputVar, equals('r0'));

    consumer.close();
    producer.close(unlink: true);
  });
}
