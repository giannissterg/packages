import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';

import 'compile_diagnostics.dart';
import 'compiler_interface.dart';
import 'compiler_ir.dart';
import 'peephole_pass.dart';
import 'program_analyzer.dart';
import 'schema_inference_pass.dart';

/// Multi-pass workflow compiler translating a Vaster AST ([Pipeline]) into
/// [VasterProgram] ISA bytecode.
///
/// Pipeline:
///  1. **Expansion** — the AST expands through [ComposableNode.build] /
///     [Provider.applyToContext] (macro expansion).
///  2. **Lowering** — nodes lower to a label-based IR ([IrModule]); control
///     flow uses symbolic labels, so nesting is correct by construction.
///  3. **Optimization** *(opt-in)* — IR peephole passes (jump-to-next and
///     dead-code elimination).
///  4. **Assembly** — two-pass label resolution to absolute PCs.
///  5. **Type inference** — `responseSchema` synthesis from [JsonExtractOp]
///     dataflow ([SchemaInferencePass]).
///  6. **Semantic analysis** — [ProgramAnalyzer] diagnostics (def-use,
///     reference and reachability checks).
class BasicWorkflowCompiler implements WorkflowCompiler {
  final CompilerOptions options;

  const BasicWorkflowCompiler({this.options = CompilerOptions.defaults});

  /// Compiles [pipeline], throwing [StateError] if any error-severity
  /// diagnostic is produced. Warnings and infos are discarded — use
  /// [compileWithDiagnostics] to inspect them.
  @override
  VasterProgram compile(Pipeline pipeline) {
    final result = compileWithDiagnostics(pipeline);
    if (result.hasErrors) {
      throw StateError(
        'Compilation failed:\n${result.errors.map((e) => '  $e').join('\n')}',
      );
    }
    return result.program;
  }

  /// Compiles [pipeline] and returns the program together with every
  /// diagnostic gathered by the analysis passes.
  CompileResult compileWithDiagnostics(Pipeline pipeline) {
    // Pass 1: expansion.
    final initialContext = BuildContext(pipelineSpec: pipeline.spec);
    final expandedTree = pipeline.build(initialContext);

    // Pass 2: lowering to label IR.
    final ir = IrModule();
    final state = _CompilerState();
    _lowerNode(expandedTree, ir, initialContext, state);
    ir.emit(const HaltOp());

    // Pass 2b: subroutine bodies — emitted after the main halt, reachable
    // only through CallOp. Bodies may define further subroutines, so drain
    // to a fixed point.
    final emittedSubs = <String>{};
    while (true) {
      final pending = state.subroutineBodies.keys
          .where((name) => !emittedSubs.contains(name))
          .toList();
      if (pending.isEmpty) break;
      for (final name in pending) {
        emittedSubs.add(name);
        ir.bind(state.subroutineLabel(ir, name));
        state.lastOutputRegister = null;
        _lowerNodes(state.subroutineBodies[name]!, ir, initialContext, state);
        ir.emit(ReturnSubroutineOp(returnRegister: state.lastOutputRegister));
      }
    }

    // Calls to subroutines that were never defined would surface as an
    // unbound-label StateError deep in assembly; report them as proper
    // compile errors instead.
    final undefinedSubs = state.subroutineLabels.keys
        .where((name) => !state.subroutineBodies.containsKey(name))
        .toList();
    if (undefinedSubs.isNotEmpty) {
      return CompileResult(
        program: VasterProgram(
          programName: pipeline.spec.name,
          instructions: const [HaltOp()],
        ),
        diagnostics: [
          for (final name in undefinedSubs)
            CompileDiagnostic(
              severity: CompileSeverity.error,
              code: 'undefined_subroutine',
              message: 'CallSubroutine references "$name", '
                  'but no DefineSubroutine with that name exists.',
            ),
        ],
      );
    }

    // Pass 3: optimization (opt-in).
    if (options.optimize) {
      final optimized = const PeepholePass().run(List.of(ir.items));
      ir.items
        ..clear()
        ..addAll(optimized);
    }

    // Pass 4: assembly (labels -> absolute PCs).
    var instructions = ir.assemble();

    // Pass 5: schema inference from dataflow.
    if (options.inferSchemas) {
      instructions = const SchemaInferencePass().run(instructions);
    }

    final program = VasterProgram(
      programName: pipeline.spec.name,
      instructions: instructions,
    );

    // Pass 6: semantic analysis.
    final diagnostics = const ProgramAnalyzer().analyze(program);

    return CompileResult(program: program, diagnostics: diagnostics);
  }

  void _lowerNodes(
    List<VasterNode> nodes,
    IrModule ir,
    BuildContext context,
    _CompilerState state,
  ) {
    for (final node in nodes) {
      _lowerNode(node, ir, context, state);
    }
  }

  void _lowerNode(
    VasterNode node,
    IrModule ir,
    BuildContext context,
    _CompilerState state,
  ) {
    switch (node) {
      case Prompt n:
        final reg = state.nextAutoRegister();
        ir.emit(PromptOp(
          promptText: n.promptText,
          outputVar: reg,
          responseSchema: n.outputSchema,
        ));
        state.lastOutputRegister = reg;

      case WriteFile n:
        ir.emit(WriteFileOp(vfsPath: n.path, content: n.content));

      case ReadFile n:
        final reg = state.nextAutoRegister();
        ir.emit(ReadFileOp(vfsPath: n.path, outputVar: reg));
        state.lastOutputRegister = reg;

      case ParallelTasks n:
        final dispatches = <ParallelTaskDispatch>[];
        for (final t in n.entries) {
          final reg = state.nextAutoRegister();
          dispatches.add(
            ParallelTaskDispatch(
              agentId: t.agentRoleId,
              taskPrompt: t.promptText,
              outputVar: reg,
            ),
          );
          state.lastOutputRegister = reg;
        }
        ir.emit(DispatchParallelTasksOp(dispatches: dispatches));

      case Execute n:
        final reg = state.nextAutoRegister();
        ir.emit(ExecSandboxOp(sandboxId: n.envId, code: n.code, outputVar: reg));
        state.lastOutputRegister = reg;

      case When n:
        // Layout (unchanged from the single-pass emitter, now label-safe for
        // arbitrary nesting):
        //   jumpIf cond -> THEN
        //   <else block>
        //   jump -> JOIN
        // THEN:
        //   <then block>
        // JOIN:
        final thenLabel = ir.newLabel('then');
        final joinLabel = ir.newLabel('join');

        ir.jumpIf(n.condition, thenLabel);
        _lowerNodes(n.otherwise, ir, context, state);
        ir.jump(joinLabel);
        ir.bind(thenLabel);
        _lowerNodes(n.then, ir, context, state);
        ir.bind(joinLabel);

      case Transaction n:
        ir.emit(const BeginTransactionOp());
        _lowerNodes(n.children, ir, context, state);
        ir.emit(const CommitOp());

      case Decide n:
        // Model-steered pattern-match. Layout:
        //   decide {label_i -> PATH_i}
        // PATH_i:
        //   <path children>
        //   jump -> JOIN
        // JOIN:
        final policy = context.tryRead<DecisionPolicy>();
        final chosenReg = state.nextAutoRegister();
        final joinLabel = ir.newLabel('decide_join');
        final pathLabels = [
          for (final path in n.paths) ir.newLabel('decide_${path.label}'),
        ];

        ir.decide(
          n.prompt,
          [
            for (var i = 0; i < n.paths.length; i++)
              IrDecideBranch(
                  n.paths[i].label, n.paths[i].description, pathLabels[i]),
          ],
          outputVar: chosenReg,
          defaultLabel: n.defaultPath ?? policy?.defaultPath,
        );
        for (var i = 0; i < n.paths.length; i++) {
          ir.bind(pathLabels[i]);
          _lowerNodes(n.paths[i].children, ir, context, state);
          ir.jump(joinLabel);
        }
        ir.bind(joinLabel);
        state.lastOutputRegister = chosenReg;

      case DecideLoop n:
        // Model-driven iteration; all machinery internal. Layout:
        //   setRegister counter = 0
        // START:
        //   <body>
        //   increment counter
        //   compare counter < maxIterations -> guardOk
        //   jumpIf guardOk -> DECIDE
        //   jump -> EXHAUST_EXIT      (forced termination)
        // DECIDE:
        //   decide {continue -> START, exit_i -> EXIT_i}
        // EXIT_i:
        //   <exit children>
        //   jump -> JOIN
        // JOIN:
        final loopPolicy = context.tryRead<DecisionPolicy>();
        final maxIterations =
            n.maxIterations ?? loopPolicy?.maxIterations ?? 8;
        final loopDefault = n.defaultPath ?? loopPolicy?.defaultPath;
        final counterReg = state.nextAutoRegister();
        final guardOkReg = state.nextAutoRegister();
        final chosenReg = state.nextAutoRegister();
        final loopStart = ir.newLabel('decide_loop_start');
        final decideLabel = ir.newLabel('decide_loop_decide');
        final joinLabel = ir.newLabel('decide_loop_join');
        final exitLabels = [
          for (final exit in n.exits) ir.newLabel('decide_loop_${exit.label}'),
        ];

        // Exhaustion must terminate: route to defaultPath's exit when it
        // names one, else the first exit — never back to the loop.
        var exhaustIndex = 0;
        for (var i = 0; i < n.exits.length; i++) {
          if (n.exits[i].label == loopDefault) exhaustIndex = i;
        }

        ir.emit(SetRegisterOp(registerName: counterReg, value: 0));
        ir.bind(loopStart);
        _lowerNodes(n.body, ir, context, state);
        ir.emit(IncrementRegisterOp(registerName: counterReg));
        ir.emit(CompareRegisterOp(
          leftVar: counterReg,
          operator: 'lt',
          rightValue: maxIterations,
          targetVar: guardOkReg,
        ));
        ir.jumpIf(guardOkReg, decideLabel);
        ir.jump(exitLabels[exhaustIndex]);
        ir.bind(decideLabel);
        ir.decide(
          n.prompt,
          [
            IrDecideBranch(n.continueLabel, n.continueDescription, loopStart),
            for (var i = 0; i < n.exits.length; i++)
              IrDecideBranch(
                  n.exits[i].label, n.exits[i].description, exitLabels[i]),
          ],
          outputVar: chosenReg,
          defaultLabel: loopDefault,
        );
        for (var i = 0; i < n.exits.length; i++) {
          ir.bind(exitLabels[i]);
          _lowerNodes(n.exits[i].children, ir, context, state);
          ir.jump(joinLabel);
        }
        ir.bind(joinLabel);
        state.lastOutputRegister = chosenReg;

      // ── Control flow ──────────────────────────────────────────────────
      case While n:
        // Layout (guarded pre-test loop):
        //   setRegister guard = 0
        // START:
        //   compare guard < maxIterations -> guardOk
        //   jumpIf guardOk -> CHECK
        //   jump -> END              (runaway guard tripped)
        // CHECK:
        //   jumpIf cond -> BODY
        //   jump -> END
        // BODY:
        //   <children>
        //   increment guard
        //   jump -> START
        // END:
        final guardReg = state.nextAutoRegister();
        final guardOkReg = state.nextAutoRegister();
        final whileStart = ir.newLabel('while_start');
        final whileCheck = ir.newLabel('while_check');
        final whileBody = ir.newLabel('while_body');
        final whileEnd = ir.newLabel('while_end');

        ir.emit(SetRegisterOp(registerName: guardReg, value: 0));
        ir.bind(whileStart);
        ir.emit(CompareRegisterOp(
          leftVar: guardReg,
          operator: 'lt',
          rightValue: n.maxIterations,
          targetVar: guardOkReg,
        ));
        ir.jumpIf(guardOkReg, whileCheck);
        ir.jump(whileEnd);
        ir.bind(whileCheck);
        ir.jumpIf(n.conditionVar, whileBody);
        ir.jump(whileEnd);
        ir.bind(whileBody);
        _lowerNodes(n.children, ir, context, state);
        ir.emit(IncrementRegisterOp(registerName: guardReg));
        ir.jump(whileStart);
        ir.bind(whileEnd);

      case Repeat n:
        // Counted pre-test loop; the counter register doubles as the
        // user-visible iteration index when [counterVar] is set.
        final counterReg = n.counterVar ?? state.nextAutoRegister();
        final cmpReg = state.nextAutoRegister();
        final repeatStart = ir.newLabel('repeat_start');
        final repeatBody = ir.newLabel('repeat_body');
        final repeatEnd = ir.newLabel('repeat_end');

        ir.emit(SetRegisterOp(registerName: counterReg, value: 0));
        ir.bind(repeatStart);
        ir.emit(CompareRegisterOp(
          leftVar: counterReg,
          operator: 'lt',
          rightValue: n.times,
          targetVar: cmpReg,
        ));
        ir.jumpIf(cmpReg, repeatBody);
        ir.jump(repeatEnd);
        ir.bind(repeatBody);
        _lowerNodes(n.children, ir, context, state);
        ir.emit(IncrementRegisterOp(registerName: counterReg));
        ir.jump(repeatStart);
        ir.bind(repeatEnd);

      case TryCatch n:
        // Layout:
        //   pushErrorHandler -> CATCH
        //   <try>
        //   popErrorHandler
        //   jump -> END
        // CATCH:                     (runtime lands here with errorVar set)
        //   <catch>
        // END:
        final catchLabel = ir.newLabel('catch');
        final tryEnd = ir.newLabel('try_end');

        ir.pushErrorHandler(catchLabel, errorVar: n.errorVar);
        _lowerNodes(n.tryChildren, ir, context, state);
        ir.emit(const PopErrorHandlerOp());
        ir.jump(tryEnd);
        ir.bind(catchLabel);
        _lowerNodes(n.catchChildren, ir, context, state);
        ir.bind(tryEnd);

      case DefineSubroutine n:
        // Bodies are emitted after the main halt (see compileWithDiagnostics)
        // so definition order never affects fall-through execution.
        state.subroutineBodies[n.name] = n.children;

      case CallSubroutine n:
        final callReg = state.nextAutoRegister();
        ir.call(
          n.name,
          state.subroutineLabel(ir, n.name),
          arguments: n.arguments.map((k, v) => MapEntry(k, v.toString())),
          outputVar: callReg,
        );
        state.lastOutputRegister = callReg;

      // ── Context management nodes ──────────────────────────────────────
      case AddContext n:
        ir.emit(AddContextOp(
          regionId: n.regionId,
          label: n.label,
          text: n.text,
          sourceVar: n.sourceVar,
          priority: n.priority.name,
          lifetime: n.lifetime.name,
          compressibility: n.compressibility.name,
          pinned: n.pinned,
        ));

      case EvictContext n:
        ir.emit(EvictContextOp(regionId: n.regionId, force: n.force));

      case PinContext n:
        ir.emit(PinContextOp(regionId: n.regionId));

      case UnpinContext n:
        ir.emit(UnpinContextOp(regionId: n.regionId));

      case ContextPolicy n:
        ir.emit(SetContextPolicyOp(
          regionId: n.regionId,
          priority: n.priority?.name,
          pinned: n.pinned,
          compressibility: n.compressibility?.name,
          utility: n.utility,
        ));

      case CompressContext n:
        final reg = state.nextAutoRegister();
        ir.emit(CompressContextOp(
          regionId: n.regionId,
          targetTokens: n.targetTokens,
          outputVar: reg,
        ));
        state.lastOutputRegister = reg;

      case YieldHuman n:
        ir.emit(YieldHumanInteractionOp(
          request: HumanInteractionRequest(
            requestId: n.requestId,
            type: HumanInteractionType.parse(n.interactionType),
            prompt: n.prompt,
            options: n.options,
            outputVar: n.outputVar,
            timeoutMs: n.timeoutMs,
          ),
        ));

      case AskHuman n:
        final reg = state.nextAutoRegister();
        ir.emit(
          YieldHumanInteractionOp(
            request: HumanInteractionRequest(
              requestId: n.requestId,
              type: HumanInteractionType.question,
              prompt: n.prompt,
              options: n.options,
              outputVar: reg,
            ),
          ),
        );
        state.lastOutputRegister = reg;

      case Output n:
        if (n.child != null) {
          _lowerNode(n.child!, ir, context, state);
        }
        final sourceReg = n.valueKey ?? state.lastOutputRegister;
        if (sourceReg != null) {
          ir.emit(ConcatRegisterOp(targetVar: '__output__', sourceVars: [sourceReg]));
        }

      case Provider n:
        final childContext = n.applyToContext(context);
        _lowerNodes(n.children, ir, childContext, state);

      case ComposableNode n:
        final expanded = n.build(context);
        _lowerNode(expanded, ir, context, state);

      // Private leaf execution nodes emitted by ComposableNode headers.
      case dynamic n when n.runtimeType.toString() == '_PipelineBody':
        _lowerNodes((n as dynamic).children as List<VasterNode>, ir, context, state);

      case dynamic n when n.runtimeType.toString() == '_AgentProvisionHeader':
        final role = (n as dynamic).role as AgentRole;
        ir.emit(
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: role.roleId,
              name: role.name,
              role: role.title,
              systemInstruction: role.instruction,
            ),
          ),
        );
        ir.emit(CreateSessionOp(sessionId: 'sess_${role.roleId}'));

      case dynamic n when n.runtimeType.toString() == '_MountHeader':
        final mount = (n as dynamic).mount as StorageMount;
        ir.emit(MountFsOp(mountPrefix: mount.mountPrefix, diskPath: mount.diskPath));

      case dynamic n when n.runtimeType.toString() == '_ToolSetHeader':
        final tools = (n as dynamic).tools as List<ToolDefinition>;
        ir.emit(RegisterToolSetOp(tools: tools));

      case dynamic n when n.runtimeType.toString() == '_BudgetHeader':
        final maxTokens = (n as dynamic).maxTokens as int?;
        final maxDuration = (n as dynamic).maxDuration as Duration?;
        ir.emit(
          SetQuotaOp(
            quota: ResourceQuota(
              maxTokenBudget: maxTokens,
              timeDeadline: maxDuration,
            ),
          ),
        );

      case dynamic n when n.runtimeType.toString() == '_SandboxHeader':
        final env = (n as dynamic).env as CodeEnvironment;
        ir.emit(RegisterSandboxOp(sandboxId: env.envId, language: env.language));

      case dynamic n when n.runtimeType.toString() == '_SelectModelHeader':
        final model = (n as dynamic).model as ModelDescriptor;
        ir.emit(SelectModelOp(descriptor: model));

      case dynamic n when n.runtimeType.toString() == '_TaskExecution':
        final reg = state.nextAutoRegister();
        final roleId = (n as dynamic).agentRoleId as String;
        final prompt = (n as dynamic).taskPrompt as String;
        final outputSchema = (n as dynamic).outputSchema as Map<String, dynamic>?;
        ir.emit(SetSessionOp(sessionId: 'sess_$roleId'));
        ir.emit(
          DispatchAgentTaskOp(
            agentId: roleId,
            taskPrompt: prompt,
            outputVar: reg,
            responseSchema: outputSchema,
          ),
        );
        state.lastOutputRegister = reg;

      case dynamic n when n.runtimeType.toString() == '_SendMessageExecution':
        final senderId = (n as dynamic).senderAgentId as String;
        final recipientId = (n as dynamic).recipientAgentId as String;
        final payload = (n as dynamic).payload as Map<String, dynamic>;
        ir.emit(
          SendMessageOp(
            senderId: senderId,
            recipientId: recipientId,
            payload: payload,
          ),
        );

      case dynamic n when n.runtimeType.toString() == '_ReceiveMessageExecution':
        final reg = state.nextAutoRegister();
        final agentId = (n as dynamic).agentId as String;
        ir.emit(PopMessageOp(agentId: agentId, outputVar: reg));
        state.lastOutputRegister = reg;

      default:
        break;
    }
  }
}

class _CompilerState {
  int _regCounter = 0;
  String? lastOutputRegister;

  /// Subroutine name -> entry label. Populated lazily on first reference
  /// (call or definition) so forward calls resolve naturally.
  final Map<String, IrLabel> subroutineLabels = {};

  /// Subroutine name -> body nodes, collected during lowering and emitted
  /// after the main program's halt.
  final Map<String, List<VasterNode>> subroutineBodies = {};

  String nextAutoRegister() {
    return '__auto_reg_${_regCounter++}';
  }

  IrLabel subroutineLabel(IrModule ir, String name) =>
      subroutineLabels.putIfAbsent(name, () => ir.newLabel('sub_$name'));
}
