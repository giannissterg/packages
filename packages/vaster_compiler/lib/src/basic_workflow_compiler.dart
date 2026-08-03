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
        ir.emit(YieldHumanInteractionOp(request: n.request));

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

  String nextAutoRegister() {
    return '__auto_reg_${_regCounter++}';
  }
}
