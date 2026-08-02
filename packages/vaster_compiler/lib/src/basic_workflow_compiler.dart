import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';

import 'compiler_interface.dart';

/// Concrete implementation of [WorkflowCompiler] that translates a
/// high-level Vaster AST ([Pipeline]) into low-level [VasterProgram] ISA bytecode.
///
/// Recursively traverses AST nodes using an exhaustive `switch` over the sealed
/// [VasterNode] hierarchy. All container and scope nodes expand seamlessly through
/// [ComposableNode.build] and [Provider.applyToContext] before compilation.
class BasicWorkflowCompiler implements WorkflowCompiler {
  const BasicWorkflowCompiler();

  @override
  VasterProgram compile(Pipeline pipeline) {
    final initialContext = BuildContext(pipelineSpec: pipeline.spec);
    final expandedTree = pipeline.build(initialContext);

    final instructions = <VasterInstruction>[];
    final state = _CompilerState();

    _compileNode(expandedTree, instructions, initialContext, state);

    instructions.add(const HaltOp());

    return VasterProgram(programName: pipeline.spec.name, instructions: instructions);
  }

  void _compileNodes(
    List<VasterNode> nodes,
    List<VasterInstruction> out,
    BuildContext context,
    _CompilerState state,
  ) {
    for (final node in nodes) {
      _compileNode(node, out, context, state);
    }
  }

  void _compileNode(
    VasterNode node,
    List<VasterInstruction> out,
    BuildContext context,
    _CompilerState state,
  ) {
    switch (node) {
      case Prompt n:
        final reg = state.nextAutoRegister();
        out.add(PromptOp(promptText: n.promptText, outputVar: reg));
        state.lastOutputRegister = reg;

      case WriteFile n:
        out.add(WriteFileOp(vfsPath: n.path, content: n.content));

      case ReadFile n:
        final reg = state.nextAutoRegister();
        out.add(ReadFileOp(vfsPath: n.path, outputVar: reg));
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
        out.add(DispatchParallelTasksOp(dispatches: dispatches));

      case Execute n:
        final reg = state.nextAutoRegister();
        out.add(ExecSandboxOp(sandboxId: n.envId, code: n.code, outputVar: reg));
        state.lastOutputRegister = reg;

      case When n:
        final thenInstructions = <VasterInstruction>[];
        _compileNodes(n.then, thenInstructions, context, state);

        final elseInstructions = <VasterInstruction>[];
        _compileNodes(n.otherwise, elseInstructions, context, state);

        final elseStart = out.length + 1;
        final thenStart = elseStart + elseInstructions.length + 1;
        final afterThen = thenStart + thenInstructions.length;

        out.add(JumpIfOp(conditionVar: n.condition, targetPc: thenStart));
        out.addAll(elseInstructions);
        out.add(JumpOp(targetPc: afterThen));
        out.addAll(thenInstructions);

      case Transaction n:
        out.add(const BeginTransactionOp());
        _compileNodes(n.children, out, context, state);
        out.add(const CommitOp());

      case YieldHuman n:
        out.add(YieldHumanInteractionOp(request: n.request));

      case AskHuman n:
        final reg = state.nextAutoRegister();
        out.add(
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
          _compileNode(n.child!, out, context, state);
        }
        final sourceReg = n.valueKey ?? state.lastOutputRegister;
        if (sourceReg != null) {
          out.add(ConcatRegisterOp(targetVar: '__output__', sourceVars: [sourceReg]));
        }

      case Provider n:
        final childContext = n.applyToContext(context);
        _compileNodes(n.children, out, childContext, state);

      case ComposableNode n:
        final expanded = n.build(context);
        _compileNode(expanded, out, context, state);

      // Handle private leaf execution nodes emitted by ComposableNode headers
      case dynamic n when n.runtimeType.toString() == '_PipelineBody':
        _compileNodes((n as dynamic).children as List<VasterNode>, out, context, state);

      case dynamic n when n.runtimeType.toString() == '_AgentProvisionHeader':
        final role = (n as dynamic).role as AgentRole;
        out.add(
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: role.roleId,
              name: role.name,
              role: role.title,
              systemInstruction: role.instruction,
            ),
          ),
        );
        out.add(CreateSessionOp(sessionId: 'sess_${role.roleId}'));

      case dynamic n when n.runtimeType.toString() == '_MountHeader':
        final mount = (n as dynamic).mount as StorageMount;
        out.add(MountFsOp(mountPrefix: mount.mountPrefix, diskPath: mount.diskPath));

      case dynamic n when n.runtimeType.toString() == '_ToolSetHeader':
        final tools = (n as dynamic).tools as List<ToolDefinition>;
        out.add(RegisterToolSetOp(tools: tools));

      case dynamic n when n.runtimeType.toString() == '_BudgetHeader':
        final maxTokens = (n as dynamic).maxTokens as int?;
        final maxDuration = (n as dynamic).maxDuration as Duration?;
        out.add(
          SetQuotaOp(
            quota: ResourceQuota(
              maxTokenBudget: maxTokens,
              timeDeadline: maxDuration,
            ),
          ),
        );

      case dynamic n when n.runtimeType.toString() == '_SandboxHeader':
        final env = (n as dynamic).env as CodeEnvironment;
        out.add(RegisterSandboxOp(sandboxId: env.envId, language: env.language));

      case dynamic n when n.runtimeType.toString() == '_SelectModelHeader':
        final model = (n as dynamic).model as ModelDescriptor;
        out.add(SelectModelOp(descriptor: model));

      case dynamic n when n.runtimeType.toString() == '_TaskExecution':
        final reg = state.nextAutoRegister();
        final roleId = (n as dynamic).agentRoleId as String;
        final prompt = (n as dynamic).taskPrompt as String;
        out.add(SetSessionOp(sessionId: 'sess_$roleId'));
        out.add(
          DispatchAgentTaskOp(
            agentId: roleId,
            taskPrompt: prompt,
            outputVar: reg,
          ),
        );
        state.lastOutputRegister = reg;

      case dynamic n when n.runtimeType.toString() == '_SendMessageExecution':
        final senderId = (n as dynamic).senderAgentId as String;
        final recipientId = (n as dynamic).recipientAgentId as String;
        final payload = (n as dynamic).payload as Map<String, dynamic>;
        out.add(
          SendMessageOp(
            senderId: senderId,
            recipientId: recipientId,
            payload: payload,
          ),
        );

      case dynamic n when n.runtimeType.toString() == '_ReceiveMessageExecution':
        final reg = state.nextAutoRegister();
        final agentId = (n as dynamic).agentId as String;
        out.add(PopMessageOp(agentId: agentId, outputVar: reg));
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
