import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'compiler_interface.dart';

/// Concrete implementation of [WorkflowCompiler] that translates a
/// high-level Workflow AST ([PipelineNode]) into low-level [VasterProgram] ISA bytecode.
///
/// Recursively traverses AST nodes and emits the corresponding ISA opcodes.
/// When a [ComposableNode] is encountered, it calls [build(context)] and
/// recursively compiles the expanded sub-tree.
class BasicWorkflowCompiler implements WorkflowCompiler {
  const BasicWorkflowCompiler();

  @override
  VasterProgram compile(PipelineNode pipeline) {
    final context = BuildContext(
      pipelineSpec: pipeline.spec,
    );

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
    // Composable nodes are expanded first by calling their build() method
    if (node is ComposableNode) {
      final expanded = node.build(context);
      _compileNode(expanded, out, context);
      return;
    }

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
        // Emit: JumpIf over else-block to then-block
        // Layout: [thenNodes...] [JumpOp past else] [elseNodes...] [merge point]
        final thenInstructions = <VasterInstruction>[];
        _compileNodes(n.thenNodes, thenInstructions, context);

        final elseInstructions = <VasterInstruction>[];
        _compileNodes(n.elseNodes, elseInstructions, context);

        // Calculate jump targets relative to current out.length
        final baseIndex = out.length;
        // JumpIf skips to then-block start (right after the jump instruction)
        final thenStart = baseIndex + 1;
        // After then-block we need to jump past else-block
        final afterElse = thenStart + thenInstructions.length + 1 + elseInstructions.length;

        out.add(JumpIfOp(
          conditionVar: n.conditionVariable,
          targetPc: thenStart,
        ));

        // else-block
        out.addAll(elseInstructions);
        // Jump past then-block (only reached when condition was false)
        out.add(JumpOp(targetPc: afterElse));
        // then-block
        out.addAll(thenInstructions);

      case StepTransactionNode n:
        out.add(const BeginTransactionOp());
        _compileNodes(n.bodyNodes, out, context);
        out.add(const CommitOp());

      case OutputNode n:
        // OutputNode emits a no-op SetRegisterOp to surface the output variable
        out.add(SetRegisterOp(
          registerName: '__output__',
          value: '\${${n.outputVariable}}',
        ));
    }
  }
}
