import 'dart:convert';
import 'dart:io';

import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'conformance_vector.dart';

/// Outcome of running one vector — sealed, carrying its data.
sealed class ConformanceOutcome {
  const ConformanceOutcome();
}

/// The runtime reproduced the vector completely.
final class ConformancePass extends ConformanceOutcome {
  final String vectorName;
  final int steps;

  const ConformancePass({required this.vectorName, required this.steps});

  @override
  String toString() => 'PASS $vectorName ($steps steps)';
}

/// First divergence between the runtime and the vector (comparison stops
/// here — later state is garbage-in). [stepIndex] is the frame ordinal;
/// final-state divergences report `stepIndex == frames.length`.
final class ConformanceFail extends ConformanceOutcome {
  final String vectorName;
  final int stepIndex;
  final JsonDivergence divergence;

  const ConformanceFail({required this.vectorName, required this.stepIndex, required this.divergence});

  @override
  String toString() => 'FAIL $vectorName at step $stepIndex — $divergence';
}

/// A loaded vector: manifest + its envelope, resolved from disk.
final class LoadedVector {
  final ConformanceVector manifest;
  final ReplayEnvelope envelope;

  const LoadedVector({required this.manifest, required this.envelope});

  /// Reads `<name>.vector.json` and its sibling envelope.
  static LoadedVector fromFile(File manifestFile) {
    final manifest = const ConformanceVectorCodec().decode(
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>,
    );
    final envelopeFile = File('${manifestFile.parent.path}/${manifest.envelopePath}');
    final envelope = const ReplayEnvelopeCodec().decodeString(envelopeFile.readAsStringSync());
    return LoadedVector(manifest: manifest, envelope: envelope);
  }
}

/// The Dart reference runner — the executable definition of the normative
/// comparison rules (docs/specs/ISA.md §Conformance procedure). A
/// second-language runtime passes conformance by doing exactly what this
/// class does to every vector.
final class ConformanceRunner {
  final JsonComparator comparator;

  const ConformanceRunner({this.comparator = const JsonComparator()});

  Future<ConformanceOutcome> run(LoadedVector vector) async {
    final manifest = vector.manifest;
    final envelope = vector.envelope;
    final program = envelope.programJson == null ? null : VasterProgram.fromJson(envelope.programJson!);
    if (program == null) {
      return ConformanceFail(
        vectorName: manifest.name,
        stepIndex: 0,
        divergence: const JsonDivergence(
          fieldPath: 'envelope.program',
          expected: 'embedded program',
          actual: '(absent)',
        ),
      );
    }
    final frames = envelope.journal.frames;

    // Truncation guard before executing anything.
    if (frames.length != manifest.expect.steps) {
      return ConformanceFail(
        vectorName: manifest.name,
        stepIndex: frames.length,
        divergence: JsonDivergence(
          fieldPath: 'length',
          expected: manifest.expect.steps,
          actual: frames.length,
        ),
      );
    }

    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: ReplayVasterModel(tape: envelope.tape)),
    );
    try {
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      if (program.contextClasses != null) {
        vm.contextManager.installClassTable(ContextClassTable.fromJson(program.contextClasses!));
      }

      RuntimeState? state;
      for (var n = 0; n < frames.length; n++) {
        final frame = frames[n];

        // pc is compared BEFORE executing step N — jumps, calls, and
        // Decide landings are all verified by the successor frame, with
        // no control-flow special cases.
        final pcBefore = state?.pc ?? 0;
        if (pcBefore != frame.pc) {
          return ConformanceFail(
            vectorName: manifest.name,
            stepIndex: n,
            divergence: JsonDivergence(fieldPath: 'pc', expected: frame.pc, actual: pcBefore),
          );
        }

        // The program is normative; the frame's embedded instruction is
        // cross-checked by opcode only (mispair detection).
        final programOpcode = program.instructions[frame.pc].opcode.name;
        final frameOpcode = frame.instruction.opcode.name;
        if (programOpcode != frameOpcode) {
          return ConformanceFail(
            vectorName: manifest.name,
            stepIndex: n,
            divergence: JsonDivergence(
              fieldPath: 'instruction.opcode',
              expected: frameOpcode,
              actual: programOpcode,
            ),
          );
        }

        state = await runtime.executeStep(program, stepCount: 1);

        // Registers are post-step snapshots; deep JSON equality after
        // normalizing the live values through a JSON round-trip.
        final actualRegisters = jsonDecode(jsonEncode(state.registers));
        final d = comparator.diff(frame.registers, actualRegisters, path: 'registers');
        if (d != null) {
          return ConformanceFail(vectorName: manifest.name, stepIndex: n, divergence: d);
        }

        // Call stack: ordered, outermost first; omitted == empty.
        final expectedStack = [for (final f in frame.callStack) f.toJson()];
        final actualStack = jsonDecode(jsonEncode([for (final f in runtime.callStackSnapshot) f.toJson()]));
        final sd = comparator.diff(expectedStack, actualStack, path: 'callStack');
        if (sd != null) {
          return ConformanceFail(vectorName: manifest.name, stepIndex: n, divergence: sd);
        }
      }

      return await _checkFinalState(manifest, program, state, runtime, vm);
    } finally {
      await vm.shutdown();
    }
  }

  Future<ConformanceOutcome> _checkFinalState(
    ConformanceVector manifest,
    VasterProgram program,
    RuntimeState? state,
    VasterRuntime runtime,
    VasterVMEngine vm,
  ) async {
    final expect = manifest.expect;
    final finalStep = expect.steps;
    ConformanceFail fail(String path, Object? expected, Object? actual) => ConformanceFail(
      vectorName: manifest.name,
      stepIndex: finalStep,
      divergence: JsonDivergence(fieldPath: path, expected: expected, actual: actual),
    );

    final status = state?.status ?? RuntimeStatus.idle;
    if (status != expect.finalStatus) {
      return fail('finalStatus', expect.finalStatus.name, status.name);
    }

    if (expect.result != null) {
      final actual = jsonDecode(jsonEncode(state!.registers[program.resultBinding]));
      final d = comparator.diff(expect.result!.value, actual, path: 'result');
      if (d != null) return ConformanceFail(vectorName: manifest.name, stepIndex: finalStep, divergence: d);
    }

    if (expect.finalStatus == RuntimeStatus.error && state!.pc != expect.trapPc) {
      return fail('trapPc', expect.trapPc, state.pc);
    }

    if (expect.pendingRequest != null) {
      final request = runtime.pendingHumanRequest;
      if (request == null) return fail('pendingRequest', expect.pendingRequest, null);
      final actual = jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>;
      for (final entry in expect.pendingRequest!.entries) {
        // Subset match: only the fields the manifest names are constrained.
        final d = comparator.diff(entry.value, actual[entry.key], path: 'pendingRequest.${entry.key}');
        if (d != null) {
          return ConformanceFail(vectorName: manifest.name, stepIndex: finalStep, divergence: d);
        }
      }
    }

    if (expect.vfs != null) {
      for (final mount in expect.vfs!.entries) {
        final fs = vm.fileSystemManager.mounts[mount.key];
        if (fs == null) return fail('vfs.${mount.key}', mount.value, null);
        final d = comparator.diff(mount.value, fs.exportFilesBase64(), path: 'vfs.${mount.key}');
        if (d != null) {
          return ConformanceFail(vectorName: manifest.name, stepIndex: finalStep, divergence: d);
        }
      }
    }

    return ConformancePass(vectorName: manifest.name, steps: expect.steps);
  }
}
