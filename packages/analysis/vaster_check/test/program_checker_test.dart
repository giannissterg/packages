import 'package:test/test.dart';
import 'package:vaster_check/vaster_check.dart';
import 'package:vaster_agent_descriptor/vaster_agent_descriptor.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// The three proofs, against hand-assembled ISA (Rule 1).
void main() {
  ProgramChecker checker({ExecutionPolicy? policy, String? model}) =>
      ProgramChecker(
        pricingCatalog: PricingCatalog.builtin,
        policy: policy,
        modelName: model,
      );

  group('binding dominance (definite assignment)', () {
    test('a straight-line read after write is clean', () {
      final report = checker().check(const VasterProgram(
        programName: 'clean',
        instructions: [
          SetRegisterOp(registerName: 'x', value: 'v'),
          PromptOp(promptText: r'use ${x}'),
          HaltOp(),
        ],
      ));
      expect(report.findings, isEmpty);
    });

    test('a read of a never-written register is an error', () {
      final report = checker().check(const VasterProgram(
        programName: 'ghost',
        instructions: [
          PromptOp(promptText: r'use ${ghost}'),
          HaltOp(),
        ],
      ));
      expect(
        report.findings.single,
        isA<ReadNeverWritten>()
            .having((f) => f.register, 'register', 'ghost')
            .having((f) => f.pc, 'pc', 0),
      );
      expect(report.hasErrors, isTrue);
    });

    test('a write on only ONE branch is a possibly-unset warning — the flat '
        'heuristic could never see this', () {
      final report = checker().check(const VasterProgram(
        programName: 'one_branch',
        instructions: [
          SetRegisterOp(registerName: 'cond', value: true), // 0
          JumpIfOp(conditionVar: 'cond', targetPc: 3), // 1
          JumpOp(targetPc: 4), // 2  (else: skip the write)
          SetRegisterOp(registerName: 'maybe', value: 'set'), // 3
          WriteFileOp(vfsPath: '/mem/out.txt', content: r'${maybe}'), // 4
          HaltOp(), // 5
        ],
      ));
      expect(
        report.findings.single,
        isA<PossiblyUnsetRead>()
            .having((f) => f.register, 'register', 'maybe')
            .having((f) => f.pc, 'pc', 4),
      );
      expect(report.hasErrors, isFalse, reason: 'a write exists: warning');
    });

    test('writes on BOTH branches dominate the read — clean', () {
      final report = checker().check(const VasterProgram(
        programName: 'both_branches',
        instructions: [
          SetRegisterOp(registerName: 'cond', value: true), // 0
          JumpIfOp(conditionVar: 'cond', targetPc: 4), // 1
          SetRegisterOp(registerName: 'v', value: 'else'), // 2
          JumpOp(targetPc: 5), // 3
          SetRegisterOp(registerName: 'v', value: 'then'), // 4
          WriteFileOp(vfsPath: '/mem/out.txt', content: r'${v}'), // 5
          HaltOp(), // 6
        ],
      ));
      expect(report.findings, isEmpty);
    });

    test('HITL and Decide sibling registers count as writes', () {
      final report = checker().check(VasterProgram(
        programName: 'siblings',
        instructions: [
          YieldHumanInteractionOp(
            request: const HumanInteractionRequest(
              requestId: 'g',
              type: HumanInteractionType.approval,
              prompt: 'ok?',
              outputVar: 'ans',
            ),
          ), // 0
          const JumpIfOp(conditionVar: 'ans_status', targetPc: 2), // 1
          const DecideOp(
            prompt: 'choose',
            branches: [
              DecisionBranch(label: 'a', description: 'a', targetPc: 3),
            ],
            outputVar: 'pick',
          ), // 2
          const WriteFileOp(
              vfsPath: '/mem/o.txt',
              content: r'${pick} because ${pick_rationale}'), // 3
          const HaltOp(), // 4
        ],
      ));
      expect(report.findings, isEmpty,
          reason: 'runtime-written siblings are part of the ABI');
    });

    test('a pause inside a subroutine still dominates post-return reads', () {
      final report = checker().check(const VasterProgram(
        programName: 'sub',
        instructions: [
          CallOp(functionName: 's', targetPc: 3, outputVar: 'ret'), // 0
          WriteFileOp(vfsPath: '/mem/o.txt', content: r'${ret}'), // 1
          HaltOp(), // 2
          SetRegisterOp(registerName: 'inner', value: 1), // 3
          ReturnSubroutineOp(returnRegister: 'inner'), // 4
        ],
      ));
      expect(report.findings, isEmpty);
    });
  });

  group('cost bounds', () {
    test('a bounded loop multiplies its calls; the bound is finite', () {
      // Compiler-shaped Repeat(times: 4) around one PromptOp.
      final report = checker(model: 'claude-sonnet-5')
          .check(const VasterProgram(
        programName: 'bounded',
        instructions: [
          SetRegisterOp(registerName: 'i', value: 0), // 0
          CompareRegisterOp(
              leftVar: 'i', operator: 'lt', rightValue: 4, targetVar: 'ok'),
          JumpIfOp(conditionVar: 'ok', targetPc: 4), // 2
          JumpOp(targetPc: 7), // 3
          PromptOp(promptText: 'loop body'), // 4
          IncrementRegisterOp(registerName: 'i'), // 5
          JumpOp(targetPc: 1), // 6  (back-edge)
          HaltOp(), // 7
        ],
      ));
      expect(report.costBound.unbounded, isFalse);
      expect(report.costBound.maxModelCalls, 4);
      expect(report.costBound.maxCostUsd, isNotNull);
      expect(report.costBound.maxCostUsd!, greaterThan(0));
    });

    test('an unguarded back-edge is reported and the bound goes unbounded',
        () {
      final report = checker(model: 'claude-sonnet-5')
          .check(const VasterProgram(
        programName: 'runaway',
        instructions: [
          SetRegisterOp(registerName: 'always', value: true), // 0
          PromptOp(promptText: 'forever'), // 1
          JumpIfOp(conditionVar: 'always', targetPc: 1), // 2 back-edge
          HaltOp(), // 3
        ],
      ));
      expect(report.costBound.unbounded, isTrue);
      expect(report.findings.whereType<UnboundedLoop>(), isNotEmpty);
      expect(report.costBound.maxCostUsd, isNull,
          reason: 'no honest dollar bound exists for an unbounded loop');
    });

    test('agent dispatch counts its tool-loop ceiling', () {
      final report = checker().check(const VasterProgram(
        programName: 'agents',
        instructions: [
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: 'w',
              name: 'W',
              role: 'r',
              systemInstruction: 's',
              maxToolCallLoops: 3,
            ),
          ),
          DispatchAgentTaskOp(agentId: 'w', taskPrompt: 'work'),
          HaltOp(),
        ],
      ));
      expect(report.costBound.maxModelCalls, 3,
          reason: 'one dispatch × the descriptor tool-loop ceiling');
    });

    test('with no rated model, the bound derives the most expensive '
        'selectable — fallback-chain members included (REL-P3)', () {
      const program = VasterProgram(
        programName: 'chained_cost',
        instructions: [
          SelectModelOp(
            descriptor:
                ModelDescriptor(provider: 'google_ai', modelId: 'gemini-2.5-flash'),
            fallbacks: [
              // The pricey member hides in the CHAIN, not the primary.
              ModelDescriptor(provider: 'google_ai', modelId: 'gemini-2.5-pro'),
            ],
          ),
          PromptOp(promptText: 'do the work'),
          HaltOp(),
        ],
      );

      expect(
          mostExpensiveSelectableModel(program, PricingCatalog.builtin),
          'gemini-2.5-pro');

      final derived = checker().check(program).costBound;
      final explicit =
          checker(model: 'gemini-2.5-pro').check(program).costBound;
      expect(derived.maxCostUsd, isNotNull,
          reason: 'a program with priceable selections is never rated '
              'tokens-only by default');
      expect(derived.maxCostUsd, explicit.maxCostUsd,
          reason: 'the derived rate IS the worst chain member\'s rate');
    });

    test('agent-declared chains are selectable too — the rated model may '
        'hide on a CreateAgentOp descriptor (GAP-3b)', () {
      const program = VasterProgram(
        programName: 'agent_chained_cost',
        instructions: [
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: 'w',
              name: 'W',
              role: 'r',
              systemInstruction: 's',
              modelDescriptor:
                  ModelDescriptor(provider: 'google_ai', modelId: 'gemini-2.0-flash'),
              modelFallbacks: [
                // The pricey member is an AGENT fallback, not a SelectModel.
                ModelDescriptor(provider: 'anthropic', modelId: 'claude-opus-5'),
              ],
            ),
          ),
          DispatchAgentTaskOp(agentId: 'w', taskPrompt: 'work'),
          HaltOp(),
        ],
      );
      expect(mostExpensiveSelectableModel(program, PricingCatalog.builtin),
          'claude-opus-5');
    });

    test('a program selecting no priceable model keeps the honest '
        'tokens-only bound', () {
      const program = VasterProgram(
        programName: 'unpriceable',
        instructions: [
          SelectModelOp(
            descriptor: ModelDescriptor(provider: 'x', modelId: 'mystery-model'),
          ),
          PromptOp(promptText: 'do the work'),
          HaltOp(),
        ],
      );
      expect(mostExpensiveSelectableModel(program, PricingCatalog.builtin),
          isNull);
      expect(checker().check(program).costBound.maxCostUsd, isNull);
    });
  });

  group('policy proofs', () {
    final readOnly = ExecutionPolicy.readOnly;

    test('a statically denied write is a PROVEN violation (error)', () {
      final report = checker(policy: readOnly).check(const VasterProgram(
        programName: 'forbidden',
        instructions: [
          WriteFileOp(vfsPath: '/mem/x.txt', content: 'boom'),
          HaltOp(),
        ],
      ));
      expect(
        report.findings.whereType<PolicyViolationProven>().single,
        isA<PolicyViolationProven>()
            .having((f) => f.resource, 'resource', '/mem/x.txt'),
      );
      expect(report.hasErrors, isTrue);
    });

    test('an interpolated resource is unprovable (warning), not assumed safe',
        () {
      final report = checker(policy: readOnly).check(const VasterProgram(
        programName: 'dynamic',
        instructions: [
          SetRegisterOp(registerName: 'p', value: '/mem/x.txt'),
          WriteFileOp(vfsPath: r'${p}', content: 'boom'),
          HaltOp(),
        ],
      ));
      expect(report.findings.whereType<PolicyUnprovable>(), hasLength(1));
      expect(report.hasErrors, isFalse);
    });

    test('an unreachable violation is NOT reported — proofs are about '
        'reachable code', () {
      final report = checker(policy: readOnly).check(const VasterProgram(
        programName: 'dead_code',
        instructions: [
          JumpOp(targetPc: 2), // 0
          WriteFileOp(vfsPath: '/mem/x.txt', content: 'dead'), // 1
          HaltOp(), // 2
        ],
      ));
      expect(report.findings.whereType<PolicyViolationProven>(), isEmpty);
      expect(report.findings.whereType<UnreachableInstruction>(),
          hasLength(1));
    });

    test('a clean read-only program is fully proven', () {
      final report = checker(policy: readOnly).check(const VasterProgram(
        programName: 'proven',
        instructions: [
          ReadFileOp(vfsPath: '/mem/in.txt', outputVar: 'data'),
          PromptOp(promptText: r'summarize ${data}'),
          HaltOp(),
        ],
      ));
      expect(report.findings, isEmpty,
          reason: 'every reachable action allowed, no dynamic resources — '
              'a proof');
    });
  });

  group('cost bound composes the estimation seam', () {
    const program = VasterProgram(
      programName: 'one_call',
      instructions: [
        PromptOp(promptText: 'a prompt of some length for the bound'),
        HaltOp(),
      ],
    );

    test('defaults are byte-identical to the heuristic era', () {
      final plain = checker().check(program).costBound;
      final explicitDefault = ProgramChecker(
        pricingCatalog: PricingCatalog.builtin,
        estimator: const HeuristicTokenEstimator(),
        callOverheadFactor: 1.0,
      ).check(program).costBound;
      expect(explicitDefault.maxTokens, plain.maxTokens);
      expect(plain.maxTokens,
          TokenEstimate.forText('a prompt of some length for the bound') + 1024);
    });

    test('a composed estimator changes the token bound', () {
      final calibrated = ProgramChecker(
        pricingCatalog: PricingCatalog.builtin,
        estimator: _FixedRatioEstimator(2.0),
      ).check(program).costBound;
      expect(
          calibrated.maxTokens,
          ('a prompt of some length for the bound'.length / 2).ceil() + 1024,
          reason: 'the analyzer estimates through the seam, not the statics');
    });

    test('the harness overhead factor scales the whole bound', () {
      final api = checker(model: 'claude-opus-5').check(program).costBound;
      final agentic = ProgramChecker(
        pricingCatalog: PricingCatalog.builtin,
        modelName: 'claude-opus-5',
        callOverheadFactor: 2.23,
      ).check(program).costBound;
      expect(agentic.maxTokens, (api.maxTokens * 2.23).ceil());
      expect(agentic.maxCostUsd, greaterThan(api.maxCostUsd! * 2.2),
          reason: 'the prove-it lesson, priced in: CLI-agentic calls cost '
              'more than their visible prompt');
    });
  });
}

/// Minimal seam implementation for the test: fixed chars-per-token.
final class _FixedRatioEstimator implements TokenEstimator {
  final double charsPerToken;
  const _FixedRatioEstimator(this.charsPerToken);
  @override
  int forText(String text) => (text.length / charsPerToken).ceil();
  @override
  int forMessages(Iterable<ChatMessage> messages) =>
      messages.fold(0, (s, m) => s + forText(m.text));
  @override
  UsageMetadata forExchange({required String prompt, required String output}) =>
      UsageMetadata(
          promptTokenCount: forText(prompt),
          candidatesTokenCount: forText(output),
          source: UsageSource.estimated);
}
