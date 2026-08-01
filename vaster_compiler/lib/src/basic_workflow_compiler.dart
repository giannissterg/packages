import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'compiler_interface.dart';

/// Concrete implementation of [WorkflowCompiler] that translates a
/// high-level Workflow AST ([PipelineNode]) into low-level [VasterProgram] ISA bytecode.
///
/// Recursively traverses AST nodes using an exhaustive `switch` over the sealed
/// [WorkflowAstNode] hierarchy. [ComposableNode] sub-trees are expanded by calling
/// [ComposableNode.build] before compilation. [ProviderNode] sub-trees receive an
/// enriched [BuildContext] with the injected typed value.
class BasicWorkflowCompiler implements WorkflowCompiler {
  const BasicWorkflowCompiler();

  @override
  VasterProgram compile(PipelineNode pipeline) {
    final context = BuildContext(pipelineSpec: pipeline.spec);
    final instructions = <VasterInstruction>[];
    _compileNodes(pipeline.bodyNodes, instructions, context);
    instructions.add(const HaltOp());
    return VasterProgram(
      programName: pipeline.spec.name,
      instructions: instructions,
    );
  }

  void _compileNodes(
    List<WorkflowAstNode> nodes,
    List<VasterInstruction> out,
    BuildContext context,
  ) {
    for (final node in nodes) {
      _compileNode(node, out, context);
    }
  }

  void _compileNode(
    WorkflowAstNode node,
    List<VasterInstruction> out,
    BuildContext context,
  ) {
    // Exhaustive switch over the sealed WorkflowAstNode hierarchy.
    switch (node) {
      case PipelineNode n:
        _compileNodes(n.bodyNodes, out, context);

      case MountStorageNode n:
        out.add(MountFsOp(
          mountPrefix: n.mount.mountPrefix,
          diskPath: n.mount.diskPath,
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

      case PerformTaskNode n:
        out.add(DispatchAgentTaskOp(
          agentId: n.agentRoleId,
          taskPrompt: n.task.promptText,
          outputVar: n.task.outputVariable,
        ));

      case PerformParallelTasksNode n:
        out.add(DispatchParallelTasksOp(
          dispatches: n.entries
              .map((e) => ParallelTaskDispatch(
                    agentId: e.agentRoleId,
                    taskPrompt: e.promptText,
                    outputVar: e.outputVariable,
                  ))
              .toList(),
        ));

      case PromptModelNode n:
        out.add(PromptOp(
          promptText: n.promptText,
          outputVar: n.outputVariable,
        ));

      case WriteDocumentNode n:
        out.add(WriteFileOp(vfsPath: n.path, content: n.content));

      case ReadDocumentNode n:
        out.add(ReadFileOp(vfsPath: n.path, outputVar: n.outputVariable));

      case ExecuteCodeNode n:
        out.add(ExecSandboxOp(
          sandboxId: n.envId,
          code: n.code,
          outputVar: n.outputVariable,
        ));

      case WhenConditionNode n:
        final thenInstructions = <VasterInstruction>[];
        _compileNodes(n.thenNodes, thenInstructions, context);

        final elseInstructions = <VasterInstruction>[];
        _compileNodes(n.elseNodes, elseInstructions, context);

        final thenStart = out.length + 1;
        final afterElse = thenStart + thenInstructions.length + 1 + elseInstructions.length;

        out.add(JumpIfOp(conditionVar: n.conditionVariable, targetPc: thenStart));
        out.addAll(elseInstructions);
        out.add(JumpOp(targetPc: afterElse));
        out.addAll(thenInstructions);

      case StepTransactionNode n:
        out.add(const BeginTransactionOp());
        _compileNodes(n.bodyNodes, out, context);
        out.add(const CommitOp());

      case OutputNode n:
        out.add(SetRegisterOp(
          registerName: '__output__',
          value: '\${${n.outputVariable}}',
        ));

      case ProviderNode n:
        // Inject the typed value into a child context and compile children
        // with the enriched context. No ISA instruction is emitted.
        final childContext = n.applyToContext(context);
        _compileNodes(n.children, out, childContext);

      case ComposableNode n:
        // Expand the composable node and recursively compile the result.
        final expanded = n.build(context);
        _compileNode(expanded, out, context);
    }
  }
}
