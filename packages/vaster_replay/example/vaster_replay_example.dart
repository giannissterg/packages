// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_replay/vaster_replay.dart';

/// Demonstrates the Vaster time-travel replay engine over a hand-built journal.
///
/// In real usage a [VasterExecutionRecorder] attaches to a live `VasterRuntime`
/// and captures these frames automatically; here we build them by hand so the
/// example stays dependency-light and runnable with `dart run`.
void main() {
  // A recorded execution: prompt -> dispatch task -> concat output -> halt.
  final journal = VasterExecutionJournal()
    ..recordStep(ExecutionStepFrame(
      stepIndex: 0,
      pc: 0,
      instruction: const PromptOp(promptText: 'Design a notes app', outputVar: 'r0'),
      registers: {'r0': 'Design a notes app'},
      vfsSnapshot: CowFileSnapshot.empty(),
    ))
    ..recordStep(ExecutionStepFrame(
      stepIndex: 1,
      pc: 1,
      instruction: const DispatchAgentTaskOp(
        agentId: 'architect',
        taskPrompt: 'Produce a design spec',
        outputVar: 'r1',
      ),
      registers: {'r0': 'Design a notes app', 'r1': 'Spec v1'},
      vfsSnapshot: CowFileSnapshot.empty(),
    ))
    ..recordStep(ExecutionStepFrame(
      stepIndex: 2,
      pc: 2,
      instruction: const HaltOp(),
      registers: {
        'r0': 'Design a notes app',
        'r1': 'Spec v1',
        '__output__': 'Spec v1',
      },
      vfsSnapshot: CowFileSnapshot.empty(),
    ));

  final engine = VasterReplayEngine(journal: journal, initialStepIndex: 2);

  print('Final register state at step ${engine.currentStepIndex}:');
  print('  ${engine.currentFrame!.registers}\n');

  // Rewind one step and inspect what the last instruction changed.
  engine.stepBack();
  final delta = engine.diffBetween(1, 2);
  print('What changed between step 1 and step 2:');
  print('  ${delta!.changes.join('\n  ')}\n');

  // Patch a register at this point in history (time-travel "what-if").
  engine.mutateRegister('r1', 'Spec v2 (patched)');
  print('After patching r1 at step ${engine.currentStepIndex}:');
  print('  ${engine.currentFrame!.registers['r1']}\n');

  // Journals are fully serializable for durable, deterministic replay.
  final wire = jsonEncode(journal.toJson());
  final restored = VasterExecutionJournal.fromJson(jsonDecode(wire));
  print('Serialized journal round-trip: ${restored.length} frames restored, '
      'last instruction = ${restored.last!.instruction.opcode.name}');
}
