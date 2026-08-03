import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_agent/vaster_agent.dart';
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
        const DispatchAgentTaskOp(
          agentId: 'architect',
          taskPrompt: 'Design the system',
          outputVar: 'design',
        ),
        const DispatchParallelTasksOp(dispatches: [
          ParallelTaskDispatch(agentId: 'a', taskPrompt: 'p1', outputVar: 'o1'),
          ParallelTaskDispatch(agentId: 'b', taskPrompt: 'p2', outputVar: 'o2'),
        ]),
        RegisterToolSetOp(tools: [
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
        ]),
        SetQuotaOp(
          quota: ResourceQuota(
            maxTokenBudget: 100000,
            maxToolCallsPerTask: 8,
          ),
        ),
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
      expect(decoded.instructions[3], isA<PromptOp>());
      expect((decoded.instructions[3] as PromptOp).responseSchema, isNotNull);
      expect(decoded.instructions[16], isA<SetContextPolicyOp>());
      expect((decoded.instructions[16] as SetContextPolicyOp).utility,
          equals(0.75), reason: 'doubles preserved exactly');
    });

    test('binary is substantially smaller than JSON text', () {
      final program = _kitchenSinkProgram();
      final binarySize = program.toBytes().length;
      final jsonSize = utf8.encode(jsonEncode(program.toJson())).length;

      expect(binarySize, lessThan(jsonSize),
          reason: 'VBC must beat JSON ($binarySize vs $jsonSize bytes)');
      // The string pool + varints should do far better than parity.
      expect(binarySize, lessThan((jsonSize * 0.75).round()),
          reason: 'expected ≥25% reduction, got '
              '${(100 - binarySize * 100 / jsonSize).toStringAsFixed(1)}%');
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
              Uint8List.fromList(utf8.encode('{"programName": "json!"}   '
                  'plus enough padding to pass the length check........'))),
          throwsA(isA<VbcDecodeException>()
              .having((e) => e.message, 'message', contains('magic'))),
        );
      });

      test('rejects truncated header', () {
        expect(
          () => VasterProgramBinary.fromBytes(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<VbcDecodeException>()
              .having((e) => e.message, 'message', contains('Truncated'))),
        );
      });

      test('rejects unsupported version', () {
        final bytes = _kitchenSinkProgram().toBytes();
        bytes[5] = 99; // version low byte
        expect(
          () => VasterProgramBinary.fromBytes(bytes),
          throwsA(isA<VbcDecodeException>()
              .having((e) => e.message, 'message', contains('version 99'))),
        );
      });

      test('detects payload corruption via checksum', () {
        final bytes = _kitchenSinkProgram().toBytes();
        bytes[bytes.length - 10] ^= 0xFF; // flip a payload byte
        expect(
          () => VasterProgramBinary.fromBytes(bytes),
          throwsA(isA<VbcDecodeException>()
              .having((e) => e.message, 'message', contains('Checksum'))),
        );
      });

      test('detects truncated payload via checksum', () {
        final bytes = _kitchenSinkProgram().toBytes();
        expect(
          () => VasterProgramBinary.fromBytes(
              Uint8List.sublistView(bytes, 0, bytes.length - 5)),
          throwsA(isA<VbcDecodeException>()),
        );
      });
    });
  });
}
