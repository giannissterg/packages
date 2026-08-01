import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'compiler_interface.dart';

/// Concrete implementation of [WorkflowCompiler] that translates a
/// high-level Workflow AST ([PipelineNode]) into low-level [VasterProgram] ISA bytecode.
///
/// Recursively traverses AST nodes using an exhaustive `switch` over the sealed
/// [WorkflowAstNode] hierarchy. [ComposableNode] sub-trees are expanded by calling
/// [ComposableNode.build] before compilation. Subroutine functions ([DefineFunctionNode])
/// are compiled into jump-isolated program memory blocks with backpatched call targets.
class BasicWorkflowCompiler implements WorkflowCompiler {
  const BasicWorkflowCompiler();

  @override
  VasterProgram compile(PipelineNode pipeline) {
    final context = BuildContext(pipelineSpec: pipeline.spec);
    final instructions = <VasterInstruction>[];
    final functionSymbols = <String, int>{};
    final pendingCalls = <int, String>{}; // instruction index -> functionName

    final mainNodes = <WorkflowAstNode>[];
    final functionNodes = <DefineFunctionNode>[];

    _extractNodes(pipeline.bodyNodes, mainNodes, functionNodes, context);

    // 1. Compile main body nodes
    _compileNodes(mainNodes, instructions, context, functionSymbols, pendingCalls);

    // 2. Compile subroutines at end of main program block (preceded by jump past subroutines)
    if (functionNodes.isNotEmpty) {
      final jumpToHaltIdx = instructions.length;
      instructions.add(const JumpOp(targetPc: 0)); // Placeholder

      for (final fnNode in functionNodes) {
        functionSymbols[fnNode.functionName] = instructions.length;
        _compileNodes(fnNode.bodyNodes, instructions, context, functionSymbols, pendingCalls);
        if (instructions.isEmpty || instructions.last is! ReturnSubroutineOp) {
          instructions.add(const ReturnSubroutineOp());
        }
      }

      final haltIdx = instructions.length;
      instructions[jumpToHaltIdx] = JumpOp(targetPc: haltIdx);
    }

    instructions.add(const HaltOp());

    // 3. Backpatch function call target PCs
    for (final entry in pendingCalls.entries) {
      final idx = entry.key;
      final fnName = entry.value;
      final targetPc = functionSymbols[fnName] ?? 0;
      final origCall = instructions[idx] as CallOp;
      instructions[idx] = CallOp(
        functionName: fnName,
        targetPc: targetPc,
        arguments: origCall.arguments,
        outputVar: origCall.outputVar,
      );
    }

    return VasterProgram(
      programName: pipeline.spec.name,
      instructions: instructions,
    );
  }

  void _extractNodes(
    List<WorkflowAstNode> sourceNodes,
    List<WorkflowAstNode> mainNodes,
    List<DefineFunctionNode> functionNodes,
    BuildContext context,
  ) {
    for (final node in sourceNodes) {
      if (node is DefineFunctionNode) {
        functionNodes.add(node);
      } else if (node is ComposableNode) {
        final expanded = node.build(context);
        _extractNodes([expanded], mainNodes, functionNodes, context);
      } else if (node is ProviderNode) {
        final childContext = node.applyToContext(context);
        _extractNodes(node.children, mainNodes, functionNodes, childContext);
      } else {
        mainNodes.add(node);
      }
    }
  }

  void _compileNodes(
    List<WorkflowAstNode> nodes,
    List<VasterInstruction> out,
    BuildContext context,
    Map<String, int> functionSymbols,
    Map<int, String> pendingCalls,
  ) {
    for (final node in nodes) {
      _compileNode(node, out, context, functionSymbols, pendingCalls);
    }
  }

  void _compileNode(
    WorkflowAstNode node,
    List<VasterInstruction> out,
    BuildContext context,
    Map<String, int> functionSymbols,
    Map<int, String> pendingCalls,
  ) {
    switch (node) {
      case PipelineNode n:
        _compileNodes(n.bodyNodes, out, context, functionSymbols, pendingCalls);

      case MountStorageNode n:
        out.add(MountFsOp(
          mountPrefix: n.mount.mountPrefix,
          diskPath: n.mount.diskPath,
        ));

      case PromptModelNode n:
        out.add(PromptOp(
          promptText: n.promptText,
          outputVar: n.outputVariable,
        ));

      case DefineRoleNode n:
        out.add(CreateAgentOp(
          descriptor: AgentDescriptor(
            agentId: n.role.roleId,
            name: n.role.name,
            role: n.role.title,
            systemInstruction: n.role.instruction,
          ),
        ));

      case WriteDocumentNode n:
        out.add(WriteFileOp(
          vfsPath: n.path,
          content: n.content,
        ));

      case ReadDocumentNode n:
        out.add(ReadFileOp(
          vfsPath: n.path,
          outputVar: n.outputVariable,
        ));

      case PerformTaskNode n:
        out.add(DispatchAgentTaskOp(
          agentId: n.agentRoleId,
          taskPrompt: n.task.promptText,
          outputVar: n.task.outputVariable,
        ));

      case PerformParallelTasksNode n:
        out.add(DispatchParallelTasksOp(
          dispatches: n.entries
              .map((t) => ParallelTaskDispatch(
                    agentId: t.agentRoleId,
                    taskPrompt: t.promptText,
                    outputVar: t.outputVariable,
                  ))
              .toList(),
        ));

      case RegisterCodeEnvironmentNode n:
        out.add(RegisterSandboxOp(
          sandboxId: n.env.envId,
          language: n.env.language,
        ));

      case ExecuteCodeNode n:
        out.add(ExecSandboxOp(
          sandboxId: n.envId,
          code: n.code,
          outputVar: n.outputVariable,
        ));

      case WhenConditionNode n:
        final thenInstructions = <VasterInstruction>[];
        _compileNodes(n.thenNodes, thenInstructions, context, functionSymbols, pendingCalls);

        final elseInstructions = <VasterInstruction>[];
        _compileNodes(n.elseNodes, elseInstructions, context, functionSymbols, pendingCalls);

        final elseStart = out.length + 1;
        final thenStart = elseStart + elseInstructions.length + 1;
        final afterThen = thenStart + thenInstructions.length;

        out.add(JumpIfOp(conditionVar: n.conditionVariable, targetPc: thenStart));
        out.addAll(elseInstructions);
        out.add(JumpOp(targetPc: afterThen));
        out.addAll(thenInstructions);

      case StepTransactionNode n:
        out.add(const BeginTransactionOp());
        _compileNodes(n.bodyNodes, out, context, functionSymbols, pendingCalls);
        out.add(const CommitOp());

      case SelectModelNode n:
        out.add(SelectModelOp(descriptor: n.model));

      case YieldHumanInteractionNode n:
        out.add(YieldHumanInteractionOp(request: n.request));

      case AskHumanQuestionNode n:
        out.add(YieldHumanInteractionOp(
          request: HumanInteractionRequest(
            requestId: n.requestId,
            type: HumanInteractionType.question,
            prompt: n.prompt,
            options: n.options,
            outputVar: n.outputVariable,
          ),
        ));

      case DefineFunctionNode _:
        // Handled during compilation pass 2
        break;

      case ReturnNode n:
        out.add(ReturnSubroutineOp(returnRegister: n.returnVariable));

      case CallFunctionNode n:
        final callIdx = out.length;
        final targetPc = functionSymbols[n.functionName] ?? 0;
        pendingCalls[callIdx] = n.functionName;
        out.add(CallOp(
          functionName: n.functionName,
          targetPc: targetPc,
          arguments: n.arguments,
          outputVar: n.outputVariable,
        ));

      case OutputNode n:
        out.add(SetRegisterOp(
          registerName: '__output__',
          value: '\${${n.outputVariable}}',
        ));

      case ProviderNode n:
        final childContext = n.applyToContext(context);
        _compileNodes(n.children, out, childContext, functionSymbols, pendingCalls);

      case ComposableNode n:
        final expanded = n.build(context);
        _compileNode(expanded, out, context, functionSymbols, pendingCalls);
    }
  }
}
