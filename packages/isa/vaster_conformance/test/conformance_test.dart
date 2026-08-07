import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_conformance/vaster_conformance.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_replay/vaster_replay.dart';

/// The Dart runtime passes its own conformance suite (1.0 gate 2): every
/// golden vector reproduces; regeneration is byte-stable; coverage gates
/// keep the vectors and ISA.md honest as opcodes are added.
void main() {
  final vectorDir = Directory('vectors');
  final manifests =
      vectorDir.listSync().whereType<File>().where((f) => f.path.endsWith('.vector.json')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('the golden set is present', () {
    expect(manifests, hasLength(vectorSpecs.length));
  });

  group('reference runner:', () {
    for (final manifestFile in manifests) {
      test(manifestFile.uri.pathSegments.last, () async {
        final vector = LoadedVector.fromFile(manifestFile);
        final outcome = await const ConformanceRunner().run(vector);
        expect(outcome, isA<ConformancePass>(), reason: '$outcome');
      });
    }
  });

  test('hand-computed anchors (the generator does not bless its own bugs)', () {
    ConformanceVector load(String name) => LoadedVector.fromFile(File('vectors/$name.vector.json')).manifest;

    expect(load('core.registers.arithmetic').expect.result!.value, '42/42');
    expect(load('core.control.jumps').expect.result!.value, 'fallthrough');
    expect(load('core.control.subroutine').expect.result!.value, 42);
    expect(load('core.control.error_handler').expect.result!.value, 'handled');
    expect(load('core.control.trap').expect.finalStatus.name, 'error');
    expect(load('core.control.trap').expect.trapPc, 1);
    expect(load('core.model.decide').expect.result!.value, 'shipped');
    expect(load('core.vfs.transactions').expect.result!.value, 'base');
    expect(
      load('core.vfs.transactions').expect.vfs!['/data']!.keys,
      containsAll(['/data/base.txt', '/data/kept.txt']),
      reason: 'committed write survives; rolled-back clobber does not',
    );
    expect(load('core.hitl.pause').expect.pendingRequest!['requestId'], 'gate');
    expect(load('core.model.prompt').expect.result!.value, 'ANSWER-TWO');
  });

  test('regeneration is byte-identical (vectors cannot drift silently)', () async {
    final tmp = Directory.systemTemp.createTempSync('vaster_conformance_regen_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    for (final spec in vectorSpecs) {
      await generateVector(spec, tmp);
      for (final suffix in ['vector.json', 'replay.json']) {
        final fresh = File('${tmp.path}/${spec.name}.$suffix').readAsStringSync();
        final committed = File('vectors/${spec.name}.$suffix').readAsStringSync();
        expect(fresh, committed, reason: '${spec.name}.$suffix drifted — regenerate deliberately');
      }
    }
  });

  test('a corrupted register is reported as the exact first divergence', () async {
    final manifestFile = File('vectors/core.registers.arithmetic.vector.json');
    final vector = LoadedVector.fromFile(manifestFile);
    // Corrupt one register value at step 1 (a=42 after the increment).
    final frames = vector.envelope.journal.frames;
    frames[1].registers['a'] = 999;

    final outcome = await const ConformanceRunner().run(vector);
    expect(outcome, isA<ConformanceFail>());
    final fail = outcome as ConformanceFail;
    expect(fail.stepIndex, 1);
    expect(fail.divergence.fieldPath, 'registers.a');
    expect(fail.divergence.expected, 999);
    expect(fail.divergence.actual, 42);
  });

  group('coverage gates:', () {
    /// Opcodes conformance vectors deliberately exclude — each names its
    /// capability class; ISA.md documents the host-dependence reason.
    const capabilityOnly = {
      InstructionOpcode.registerSandbox, // live sandbox backends
      InstructionOpcode.execSandbox, // host execution output
    };

    test('every core opcode is exercised by at least one vector', () {
      final exercised = <String>{};
      for (final manifestFile in manifests) {
        final vector = LoadedVector.fromFile(manifestFile);
        final program = VasterProgram.fromJson(vector.envelope.programJson!);
        exercised.addAll([for (final i in program.instructions) i.opcode.name]);
      }
      final missing = [
        for (final opcode in InstructionOpcode.values)
          if (!capabilityOnly.contains(opcode) && !exercised.contains(opcode.name)) opcode.name,
      ];
      expect(missing, isEmpty, reason: 'core opcodes with no conformance vector');
    });

    test('every opcode appears in docs/specs/ISA.md', () {
      final doc = File('../../../docs/specs/ISA.md').readAsStringSync();
      final missing = [
        for (final opcode in InstructionOpcode.values)
          if (!doc.contains('`${opcode.name}`')) opcode.name,
      ];
      expect(missing, isEmpty, reason: 'opcodes missing from the ISA reference');
    });
  });

  group('VBC gaps closed:', () {
    test('v2 header (resultBinding + contextClasses) survives the binary round-trip', () {
      final program = VasterProgram(
        programName: 'header_probe',
        resultBinding: 'out',
        contextClasses: {
          'classes': [
            {'name': 'knowledge', 'band': 1},
          ],
        },
        instructions: const [
          SetRegisterOp(registerName: 'out', value: 1),
          HaltOp(),
        ],
      );
      final decoded = VasterProgramBinary.fromBytes(program.toBytes());
      expect(decoded.resultBinding, 'out');
      expect(jsonEncode(decoded.contextClasses), jsonEncode(program.contextClasses));
      expect(decoded.programName, 'header_probe');
    });
  });

  test('every envelope decodes through the one codec owner', () {
    for (final manifestFile in manifests) {
      final vector = LoadedVector.fromFile(manifestFile);
      expect(vector.envelope.version, 2);
      expect(vector.envelope.programJson, isNotNull);
      expect(
        const ReplayEnvelopeCodec()
            .decodeString(File('vectors/${vector.manifest.envelopePath}').readAsStringSync())
            .journal
            .length,
        vector.manifest.expect.steps,
      );
    }
  });
}
