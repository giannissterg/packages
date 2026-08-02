import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

import 'compiler_interface.dart';

/// Concrete implementation of [WorkflowCompiler] that translates a
/// high-level Vaster AST ([Pipeline]) into low-level [VasterProgram] ISA bytecode.
///
/// Recursively traverses AST nodes using an exhaustive `switch` over the sealed
/// [VasterNode] hierarchy. [ComposableNode] sub-trees are expanded by calling
/// [ComposableNode.build] before compilation. Subroutine functions ([Subroutine])
/// are compiled into jump-isolated program memory blocks with backpatched call targets.
class BasicWorkflowCompiler implements WorkflowCompiler {
  const BasicWorkflowCompiler();

  @override
  VasterProgram compile(Pipeline pipeline) {
    final context = BuildContext(pipelineSpec: pipeline.spec);
    final instructions = <VasterInstruction>[];
    final functionSymbols = <String, int>{};
    final pendingCalls = <int, String>{}; // instruction index -> functionName

    final mainNodes = <VasterNode>[];
    final functionNodes = <_ExtractedFunction>[];

    _extractNodes(pipeline.children, mainNodes, functionNodes, context);

    // 1. Compile main body nodes
    _compileNodes(mainNodes, instructions, context, functionSymbols, pendingCalls);

    // 2. Compile subroutines at end of main program block (preceded by jump past subroutines)
    if (functionNodes.isNotEmpty) {
      final jumpToHaltIdx = instructions.length;
      instructions.add(const JumpOp(targetPc: 0)); // Placeholder

      for (final fn in functionNodes) {
        functionSymbols[fn.node.name] = instructions.length;
        _compileNodes(fn.node.children, instructions, fn.context, functionSymbols, pendingCalls);
        if (instructions.isEmpty || instructions.last is! ReturnSubroutineOp) {
          instructions.add(const ReturnSubroutineOp());
        }
      }

      final haltIdx = instructions.length;
      instructions[jumpToHaltIdx] = JumpOp(targetPc: haltIdx);
    }

    instructions.add(const HaltOp());

    // 3. Backpatch function call target PCs
    for (int i = 0; i < instructions.length; i++) {
      final inst = instructions[i];
      if (inst is CallOp) {
        final targetPc = functionSymbols[inst.functionName] ?? 0;
        instructions[i] = CallOp(
          functionName: inst.functionName,
          targetPc: targetPc,
          arguments: inst.arguments,
          outputVar: inst.outputVar,
        );
      }
    }

    return VasterProgram(programName: pipeline.spec.name, instructions: instructions);
  }

  void _extractNodes(
    List<VasterNode> sourceNodes,
    List<VasterNode> mainNodes,
    List<_ExtractedFunction> functionNodes,
    BuildContext context,
  ) {
    for (final node in sourceNodes) {
      if (node is Subroutine) {
        functionNodes.add(_ExtractedFunction(node, context));
      } else if (node is ComposableNode) {
        final expanded = node.build(context);
        _extractNodes([expanded], mainNodes, functionNodes, context);
      } else if (node is Provider) {
        final childContext = node.applyToContext(context);
        _extractNodes(node.children, mainNodes, functionNodes, childContext);
      } else {
        mainNodes.add(node);
      }
    }
  }

  void _compileNodes(
    List<VasterNode> nodes,
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
    VasterNode node,
    List<VasterInstruction> out,
    BuildContext context,
    Map<String, int> functionSymbols,
    Map<int, String> pendingCalls,
  ) {
    switch (node) {
      case Pipeline n:
        _compileNodes(n.children, out, context, functionSymbols, pendingCalls);

      case Mount n:
        out.add(MountFsOp(mountPrefix: n.mount.mountPrefix, diskPath: n.mount.diskPath));

      case Prompt n:
        out.add(PromptOp(promptText: n.promptText, outputVar: n.output));

      case Agent n:
        out.add(
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: n.role.roleId,
              name: n.role.name,
              role: n.role.title,
              systemInstruction: n.role.instruction,
            ),
          ),
        );
        out.add(CreateSessionOp(sessionId: 'sess_${n.role.roleId}'));

      case WriteFile n:
        out.add(WriteFileOp(vfsPath: n.path, content: n.content));

      case ReadFile n:
        out.add(ReadFileOp(vfsPath: n.path, outputVar: n.output));

      case Task n:
        out.add(SetSessionOp(sessionId: 'sess_${n.agentRoleId}'));
        out.add(
          DispatchAgentTaskOp(
            agentId: n.agentRoleId,
            taskPrompt: n.task.promptText,
            outputVar: n.task.output,
          ),
        );

      case ParallelTasks n:
        out.add(
          DispatchParallelTasksOp(
            dispatches: n.entries
                .map(
                  (t) => ParallelTaskDispatch(
                    agentId: t.agentRoleId,
                    taskPrompt: t.promptText,
                    outputVar: t.output,
                  ),
                )
                .toList(),
          ),
        );

      case Sandbox n:
        out.add(RegisterSandboxOp(sandboxId: n.env.envId, language: n.env.language));

      case Execute n:
        out.add(ExecSandboxOp(sandboxId: n.envId, code: n.code, outputVar: n.output));

      case When n:
        final thenInstructions = <VasterInstruction>[];
        _compileNodes(n.then, thenInstructions, context, functionSymbols, pendingCalls);

        final elseInstructions = <VasterInstruction>[];
        _compileNodes(n.otherwise, elseInstructions, context, functionSymbols, pendingCalls);

        final elseStart = out.length + 1;
        final thenStart = elseStart + elseInstructions.length + 1;
        final afterThen = thenStart + thenInstructions.length;

        out.add(JumpIfOp(conditionVar: n.condition, targetPc: thenStart));
        out.addAll(elseInstructions);
        out.add(JumpOp(targetPc: afterThen));
        out.addAll(thenInstructions);

      case Transaction n:
        out.add(const BeginTransactionOp());
        _compileNodes(n.children, out, context, functionSymbols, pendingCalls);
        out.add(const CommitOp());

      case SelectModel n:
        out.add(SelectModelOp(descriptor: n.model));

      case YieldHuman n:
        out.add(YieldHumanInteractionOp(request: n.request));

      case AskHuman n:
        out.add(
          YieldHumanInteractionOp(
            request: HumanInteractionRequest(
              requestId: n.requestId,
              type: HumanInteractionType.question,
              prompt: n.prompt,
              options: n.options,
              outputVar: n.output,
            ),
          ),
        );

      case Subroutine _:
        // Handled during compilation pass 2
        break;

      case Return n:
        out.add(ReturnSubroutineOp(returnRegister: n.value));

      case Call n:
        final callIdx = out.length;
        final targetPc = functionSymbols[n.name] ?? 0;
        pendingCalls[callIdx] = n.name;
        out.add(
          CallOp(
            functionName: n.name,
            targetPc: targetPc,
            arguments: n.arguments,
            outputVar: n.output,
          ),
        );

      case Output n:
        out.add(ConcatRegisterOp(targetVar: '__output__', sourceVars: [n.output]));

      case Provider n:
        final childContext = n.applyToContext(context);
        _compileNodes(n.children, out, childContext, functionSymbols, pendingCalls);

      case ComposableNode n:
        final expanded = n.build(context);
        _compileNode(expanded, out, context, functionSymbols, pendingCalls);
    }
  }
}

class _ExtractedFunction {
  final Subroutine node;
  final BuildContext context;
  const _ExtractedFunction(this.node, this.context);
}
