import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_agent_descriptor/vaster_agent_descriptor.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// A program exercising every operand shape in the ISA: strings, nulls,
/// bools, ints, doubles, nested maps (schemas, payloads, quotas), nested
/// lists (parallel dispatches, tool definitions), and jumps.
VasterProgram _kitchenSinkProgram() => VasterProgram(
  programName: 'kitchen_sink',
  instructions: [
    const CreateAgentOp(
      descriptor: AgentDescriptor(
        agentId: 'architect',
        name: 'Architect',
        role: 'Lead',
        systemInstruction: 'Design things well.',
      ),
    ),
    const CreateSessionOp(sessionId: 'sess_architect'),
    const SetSessionOp(sessionId: 'sess_architect'),
    const PromptOp(
      promptText: 'Produce JSON',
      outputVar: 'r0',
      responseSchema: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'score': {'type': 'number'},
        },
        'required': ['title'],
        'additionalProperties': false,
      },
    ),
    const JsonExtractOp(sourceVar: 'r0', jsonKey: 'title', targetVar: 't'),
    const DispatchAgentTaskOp(agentId: 'architect', taskPrompt: 'Design the system', outputVar: 'design'),
    const DispatchParallelTasksOp(
      dispatches: [
        ParallelTaskDispatch(agentId: 'a', taskPrompt: 'p1', outputVar: 'o1'),
        ParallelTaskDispatch(agentId: 'b', taskPrompt: 'p2', outputVar: 'o2'),
      ],
    ),
    const DecideOp(
      prompt: 'Which path should we take?',
      branches: [
        DecisionBranch(label: 'approve', description: 'looks good', targetPc: 3),
        DecisionBranch(label: 'reject', description: 'needs work', targetPc: 7),
      ],
      outputVar: 'verdict',
      defaultLabel: 'reject',
    ),
    RegisterToolSetOp(
      tools: [
        const ToolDefinition(
          name: 'read_file',
          description: 'Read a file',
          parametersSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        ),
      ],
    ),
    SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 100000, maxToolCallsPerTask: 8)),
    const SendMessageOp(
      senderId: 'a',
      recipientId: 'b',
      payload: {'text': 'hello', 'turn': 3, 'urgent': true},
    ),
    const PopMessageOp(agentId: 'b', outputVar: 'inbox'),
    const WriteFileOp(vfsPath: '/mem/plan.md', content: '# Plan\nstep 1'),
    const ReadFileOp(vfsPath: '/mem/plan.md', outputVar: 'plan'),
    const BeginTransactionOp(),
    const CommitOp(),
    const AddContextOp(
      regionId: 'brief',
      label: 'the brief',
      text: 'Build a notes app',
      priority: 'high',
      compressibility: 'summarize',
      pinned: true,
    ),
    const SetContextPolicyOp(regionId: 'brief', utility: 0.75),
    const CompressContextOp(targetTokens: 5000, outputVar: 'freed'),
    const EvictContextOp(regionId: 'brief', force: true),
    YieldHumanInteractionOp(
      request: const HumanInteractionRequest(
        requestId: 'approve_1',
        type: HumanInteractionType.approval,
        prompt: 'Ship it?',
        options: ['yes', 'no'],
        outputVar: 'approval',
      ),
    ),
    const JumpIfOp(conditionVar: 'approval_status', targetPc: 22),
    const JumpOp(targetPc: 23),
    const SetRegisterOp(registerName: 'result', value: 'approved'),
    const ConcatRegisterOp(targetVar: '__output__', sourceVars: ['result']),
    const HaltOp(),
  ],
);

void main() {
  group('VBC binary format', () {
    test('kitchen-sink program round-trips with exact fidelity', () {
      final program = _kitchenSinkProgram();
      final bytes = program.toBytes();
      final decoded = VasterProgramBinary.fromBytes(bytes);

      expect(decoded.programName, equals(program.programName));
      expect(decoded.instructions.length, equals(program.instructions.length));

      // Canonical-JSON equality per instruction: every operand of every op
      // survives byte-for-byte.
      for (var i = 0; i < program.instructions.length; i++) {
        expect(
          jsonEncode(decoded.instructions[i].toJson()),
          equals(jsonEncode(program.instructions[i].toJson())),
          reason: 'instruction $i (${program.instructions[i].opcode.name})',
        );
      }
      // And the decoded ops are real typed instances, not raw maps.
      final typedPrompt = decoded.instructions.whereType<PromptOp>().firstWhere(
        (p) => p.responseSchema != null,
      );
      expect(typedPrompt.responseSchema, isNotNull);
      final policyOp = decoded.instructions.whereType<SetContextPolicyOp>().single;
      expect(policyOp.utility, equals(0.75), reason: 'doubles preserved exactly');
      final decideOp = decoded.instructions.whereType<DecideOp>().single;
      expect(decideOp.branches, hasLength(2));
      expect(decideOp.branches[1].targetPc, equals(7));
      expect(decideOp.defaultLabel, equals('reject'));
    });

    test('binary is substantially smaller than JSON text', () {
      final program = _kitchenSinkProgram();
      final binarySize = program.toBytes().length;
      final jsonSize = utf8.encode(jsonEncode(program.toJson())).length;

      expect(binarySize, lessThan(jsonSize), reason: 'VBC must beat JSON ($binarySize vs $jsonSize bytes)');
      // The string pool + varints should do far better than parity.
      expect(
        binarySize,
        lessThan((jsonSize * 0.75).round()),
        reason:
            'expected ≥25% reduction, got '
            '${(100 - binarySize * 100 / jsonSize).toStringAsFixed(1)}%',
      );
    });

    test('empty program round-trips', () {
      const program = VasterProgram(programName: 'empty', instructions: []);
      final decoded = VasterProgramBinary.fromBytes(program.toBytes());
      expect(decoded.programName, equals('empty'));
      expect(decoded.instructions, isEmpty);
    });

    group('corruption handling', () {
      test('rejects non-VBC bytes', () {
        expect(
          () => VasterProgramBinary.fromBytes(
            Uint8List.fromList(
              utf8.encode(
                '{"programName": "json!"}   '
                'plus enough padding to pass the length check........',
              ),
            ),
          ),
          throwsA(isA<VbcDecodeException>().having((e) => e.message, 'message', contains('magic'))),
        );
      });

      test('rejects truncated header', () {
        expect(
          () => VasterProgramBinary.fromBytes(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<VbcDecodeException>().having((e) => e.message, 'message', contains('Truncated'))),
        );
      });

      test('rejects unsupported version', () {
        final bytes = _kitchenSinkProgram().toBytes();
        bytes[5] = 99; // version low byte
        expect(
          () => VasterProgramBinary.fromBytes(bytes),
          throwsA(isA<VbcDecodeException>().having((e) => e.message, 'message', contains('version 99'))),
        );
      });

      test('detects payload corruption via checksum', () {
        final bytes = _kitchenSinkProgram().toBytes();
        bytes[bytes.length - 10] ^= 0xFF; // flip a payload byte
        expect(
          () => VasterProgramBinary.fromBytes(bytes),
          throwsA(isA<VbcDecodeException>().having((e) => e.message, 'message', contains('Checksum'))),
        );
      });

      test('detects truncated payload via checksum', () {
        final bytes = _kitchenSinkProgram().toBytes();
        expect(
          () => VasterProgramBinary.fromBytes(Uint8List.sublistView(bytes, 0, bytes.length - 5)),
          throwsA(isA<VbcDecodeException>()),
        );
      });

      test('rejects unknown opcodes instead of silently decoding them', () {
        expect(
          () => VasterInstruction.fromJson({'opcode': 'quantum_entangle', 'outputVar': 'x'}),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('quantum_entangle'))),
        );
        expect(() => VasterInstruction.fromJson({'outputVar': 'x'}), throwsA(isA<FormatException>()));
      });
    });

    // The committed fixtures were produced by the REAL historical encoders
    // (gate-1 discipline: versioned migration, proven — not just written):
    //   v1_program.vbc          — formatVersion 1, encoded at 49c0308^
    //   v2_legacy_classes.vbc   — early v2 whose header value WAS the
    //                             class-table map, encoded at 49c0308
    // Regeneration recipe: `git worktree add <tmp> <commit>`, add a bin
    // script in the worktree's packages/vaster_instruction importing the
    // old package, call program.toBytes(), copy the bytes out. The
    // .expected.json goldens are the CURRENT toolchain's serialization of
    // the verified decode, locked.
    group('version migration (legacy golden bytes):', () {
      Uint8List fixtureBytes(String name) => File('test/fixtures/$name.vbc').readAsBytesSync();
      Map<String, dynamic> golden(String name) =>
          jsonDecode(File('test/fixtures/$name.expected.json').readAsStringSync()) as Map<String, dynamic>;

      test('v1 bytes decode: no header, exact instruction stream', () {
        final program = VasterProgramBinary.fromBytes(fixtureBytes('v1_program'));
        expect(program.programName, 'v1_compat_probe');
        expect(program.resultBinding, isNull, reason: 'v1 predates the header');
        expect(program.contextClasses, isNull);
        expect(program.instructions, hasLength(8));
        expect(jsonEncode(program.toJson()), jsonEncode(golden('v1_program')));
      });

      test('early-v2 bytes decode: the classes-as-header sniff branch', () {
        final program = VasterProgramBinary.fromBytes(fixtureBytes('v2_legacy_classes'));
        expect(program.programName, 'v2_legacy_classes_probe');
        expect(
          program.contextClasses,
          containsPair('classes', anything),
          reason: 'the header value WAS the class table in early v2',
        );
        expect(jsonEncode(program.toJson()), jsonEncode(golden('v2_legacy_classes')));
      });

      test('upgrade round-trip: legacy decode → current encode → identical program', () {
        for (final name in ['v1_program', 'v2_legacy_classes']) {
          final legacy = VasterProgramBinary.fromBytes(fixtureBytes(name));
          final upgraded = legacy.toBytes();
          expect(
            upgraded[4] * 256 + upgraded[5],
            VbcCodec.formatVersion,
            reason: 'the migration path re-encodes at the current version',
          );
          final decoded = VasterProgramBinary.fromBytes(upgraded);
          expect(
            jsonEncode(decoded.toJson()),
            jsonEncode(legacy.toJson()),
            reason: '$name must survive the upgrade byte-for-byte in JSON terms',
          );
        }
      });

      test('legacy fixture corruption still fails typed', () {
        final bytes = Uint8List.fromList(fixtureBytes('v1_program'));
        bytes[bytes.length - 3] ^= 0xFF;
        expect(() => VasterProgramBinary.fromBytes(bytes), throwsA(isA<VbcDecodeException>()));
      });
    });
  });
}
