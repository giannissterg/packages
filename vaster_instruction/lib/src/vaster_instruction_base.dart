import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'instruction_opcode.dart';

/// Serializable task dispatch record for parallel multi-agent executions.
class ParallelTaskDispatch {
  final String agentId;
  final String taskPrompt;
  final String? outputVar;

  const ParallelTaskDispatch({
    required this.agentId,
    required this.taskPrompt,
    this.outputVar,
  });

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'taskPrompt': taskPrompt,
        if (outputVar != null) 'outputVar': outputVar,
      };

  factory ParallelTaskDispatch.fromJson(Map<String, dynamic> json) {
    return ParallelTaskDispatch(
      agentId: json['agentId'] as String? ?? '',
      taskPrompt: json['taskPrompt'] as String? ?? '',
      outputVar: json['outputVar'] as String?,
    );
  }
}

/// Sealed abstract class representing a low-level Vaster ISA instruction opcode.
sealed class VasterInstruction {
  final InstructionOpcode opcode;

  const VasterInstruction(this.opcode);

  Map<String, dynamic> toJson();

  factory VasterInstruction.fromJson(Map<String, dynamic> json) {
    final opStr = json['opcode'] as String? ?? 'prompt';
    final opcode = InstructionOpcode.parse(opStr);

    return switch (opcode) {
      InstructionOpcode.prompt => PromptOp(
          promptText: json['promptText'] as String? ?? '',
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.mountFs => MountFsOp(
          mountPrefix: json['mountPrefix'] as String? ?? '/mem',
          diskPath: json['diskPath'] as String?,
        ),
      InstructionOpcode.writeFile => WriteFileOp(
          vfsPath: json['vfsPath'] as String? ?? '',
          content: json['content'] as String? ?? '',
        ),
      InstructionOpcode.readFile => ReadFileOp(
          vfsPath: json['vfsPath'] as String? ?? '',
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.registerSandbox => RegisterSandboxOp(
          sandboxId: json['sandboxId'] as String? ?? '',
          language: SandboxLanguage.parse(json['language'] as String? ?? 'dart'),
        ),
      InstructionOpcode.execSandbox => ExecSandboxOp(
          sandboxId: json['sandboxId'] as String? ?? '',
          code: json['code'] as String? ?? '',
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.createAgent => CreateAgentOp(
          descriptor: AgentDescriptor.fromJson(json['descriptor'] as Map<String, dynamic>? ?? {}),
        ),
      InstructionOpcode.dispatchAgentTask => DispatchAgentTaskOp(
          agentId: json['agentId'] as String? ?? '',
          taskPrompt: json['taskPrompt'] as String? ?? '',
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.dispatchParallelTasks => DispatchParallelTasksOp(
          dispatches: (json['dispatches'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map((d) => ParallelTaskDispatch.fromJson(d))
              .toList(),
        ),
      InstructionOpcode.sendMessage => SendMessageOp(
          senderId: json['senderId'] as String? ?? '',
          recipientId: json['recipientId'] as String? ?? '',
          payload: Map<String, dynamic>.from(json['payload'] as Map? ?? {}),
        ),
      InstructionOpcode.forkSession => ForkSessionOp(
          sourceSessionId: json['sourceSessionId'] as String? ?? '',
          targetSessionId: json['targetSessionId'] as String? ?? '',
        ),
      InstructionOpcode.pinContext => PinContextOp(
          regionId: json['regionId'] as String? ?? '',
        ),
      InstructionOpcode.setQuota => SetQuotaOp(
          quota: ResourceQuota.fromJson(json['quota'] as Map<String, dynamic>? ?? {}),
        ),
      InstructionOpcode.jump => JumpOp(
          targetPc: json['targetPc'] as int? ?? 0,
        ),
      InstructionOpcode.jumpIf => JumpIfOp(
          targetPc: json['targetPc'] as int? ?? 0,
          conditionVar: json['conditionVar'] as String? ?? '',
        ),
      InstructionOpcode.setRegister => SetRegisterOp(
          registerName: json['registerName'] as String? ?? '',
          value: json['value'],
        ),
      InstructionOpcode.jsonExtract => JsonExtractOp(
          sourceVar: json['sourceVar'] as String? ?? '',
          jsonKey: json['jsonKey'] as String? ?? '',
          targetVar: json['targetVar'] as String? ?? '',
        ),
      InstructionOpcode.concatRegister => ConcatRegisterOp(
          targetVar: json['targetVar'] as String? ?? '',
          sourceVars: (json['sourceVars'] as List? ?? []).map((e) => e.toString()).toList(),
        ),
      InstructionOpcode.beginTransaction => const BeginTransactionOp(),
      InstructionOpcode.commit => const CommitOp(),
      InstructionOpcode.rollback => const RollbackOp(),
      InstructionOpcode.selectModel => SelectModelOp(
          descriptor: ModelDescriptor.fromJson(json['descriptor'] as Map<String, dynamic>? ?? {}),
        ),
      InstructionOpcode.createSession => CreateSessionOp(
          sessionId: json['sessionId'] as String? ?? '',
          modelDescriptor: json['modelDescriptor'] != null
              ? ModelDescriptor.fromJson(json['modelDescriptor'] as Map<String, dynamic>)
              : null,
        ),
      InstructionOpcode.setSession => SetSessionOp(
          sessionId: json['sessionId'] as String? ?? '',
        ),
      InstructionOpcode.checkPolicy => CheckPolicyOp(
          action: PolicyAction.parse(json['action'] as String? ?? ''),
          resource: json['resource'] as String? ?? '',
        ),
      InstructionOpcode.yieldHumanInteraction => YieldHumanInteractionOp(
          request: HumanInteractionRequest.fromJson(json['request'] as Map<String, dynamic>? ?? {}),
        ),
      InstructionOpcode.call => CallOp(
          functionName: json['functionName'] as String? ?? 'anonymous',
          targetPc: json['targetPc'] as int? ?? 0,
          arguments: Map<String, String>.from(json['arguments'] as Map? ?? {}),
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.returnSubroutine => ReturnSubroutineOp(
          returnRegister: json['returnRegister'] as String?,
        ),
      InstructionOpcode.halt => const HaltOp(),
    };
  }
}

/// Prompts model and stores result in [outputVar].
final class PromptOp extends VasterInstruction {
  final String promptText;
  final String? outputVar;

  const PromptOp({required this.promptText, this.outputVar})
      : super(InstructionOpcode.prompt);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'promptText': promptText,
        if (outputVar != null) 'outputVar': outputVar,
      };
}

/// Mounts virtual filesystem.
final class MountFsOp extends VasterInstruction {
  final String mountPrefix;
  final String? diskPath;

  const MountFsOp({required this.mountPrefix, this.diskPath})
      : super(InstructionOpcode.mountFs);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'mountPrefix': mountPrefix,
        if (diskPath != null) 'diskPath': diskPath,
      };
}

/// Writes file to VFS.
final class WriteFileOp extends VasterInstruction {
  final String vfsPath;
  final String content;

  const WriteFileOp({required this.vfsPath, required this.content})
      : super(InstructionOpcode.writeFile);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'vfsPath': vfsPath,
        'content': content,
      };
}

/// Reads file from VFS into [outputVar].
final class ReadFileOp extends VasterInstruction {
  final String vfsPath;
  final String? outputVar;

  const ReadFileOp({required this.vfsPath, this.outputVar})
      : super(InstructionOpcode.readFile);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'vfsPath': vfsPath,
        if (outputVar != null) 'outputVar': outputVar,
      };
}

/// Registers sandbox.
final class RegisterSandboxOp extends VasterInstruction {
  final String sandboxId;
  final SandboxLanguage language;

  const RegisterSandboxOp({required this.sandboxId, this.language = SandboxLanguage.dart})
      : super(InstructionOpcode.registerSandbox);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sandboxId': sandboxId,
        'language': language.name,
      };
}

/// Executes sandbox code.
final class ExecSandboxOp extends VasterInstruction {
  final String sandboxId;
  final String code;
  final String? outputVar;

  const ExecSandboxOp({required this.sandboxId, required this.code, this.outputVar})
      : super(InstructionOpcode.execSandbox);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sandboxId': sandboxId,
        'code': code,
        if (outputVar != null) 'outputVar': outputVar,
      };
}

/// Provisions new agent using [AgentDescriptor] handle.
final class CreateAgentOp extends VasterInstruction {
  final AgentDescriptor descriptor;

  const CreateAgentOp({required this.descriptor})
      : super(InstructionOpcode.createAgent);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'descriptor': descriptor.toJson(),
      };
}

/// Dispatches agent task.
final class DispatchAgentTaskOp extends VasterInstruction {
  final String agentId;
  final String taskPrompt;
  final String? outputVar;

  const DispatchAgentTaskOp({
    required this.agentId,
    required this.taskPrompt,
    this.outputVar,
  }) : super(InstructionOpcode.dispatchAgentTask);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'agentId': agentId,
        'taskPrompt': taskPrompt,
        if (outputVar != null) 'outputVar': outputVar,
      };
}

/// Dispatches parallel tasks across multiple agents concurrently.
final class DispatchParallelTasksOp extends VasterInstruction {
  final List<ParallelTaskDispatch> dispatches;

  const DispatchParallelTasksOp({required this.dispatches})
      : super(InstructionOpcode.dispatchParallelTasks);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'dispatches': dispatches.map((d) => d.toJson()).toList(),
      };
}

/// Sends inter-agent message.
final class SendMessageOp extends VasterInstruction {
  final String senderId;
  final String recipientId;
  final Map<String, dynamic> payload;

  const SendMessageOp({
    required this.senderId,
    required this.recipientId,
    required this.payload,
  }) : super(InstructionOpcode.sendMessage);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'senderId': senderId,
        'recipientId': recipientId,
        'payload': payload,
      };
}

/// Forks session thread.
final class ForkSessionOp extends VasterInstruction {
  final String sourceSessionId;
  final String targetSessionId;

  const ForkSessionOp({
    required this.sourceSessionId,
    required this.targetSessionId,
  }) : super(InstructionOpcode.forkSession);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sourceSessionId': sourceSessionId,
        'targetSessionId': targetSessionId,
      };
}

/// Pins context region.
final class PinContextOp extends VasterInstruction {
  final String regionId;

  const PinContextOp({required this.regionId})
      : super(InstructionOpcode.pinContext);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'regionId': regionId,
      };
}

/// Sets resource quota.
final class SetQuotaOp extends VasterInstruction {
  final ResourceQuota quota;

  const SetQuotaOp({required this.quota})
      : super(InstructionOpcode.setQuota);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'quota': quota.toJson(),
      };
}

/// Unconditional jump to [targetPc].
final class JumpOp extends VasterInstruction {
  final int targetPc;

  const JumpOp({required this.targetPc}) : super(InstructionOpcode.jump);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'targetPc': targetPc,
      };
}

/// Conditional jump to [targetPc] if [conditionVar] is non-null / true / non-empty.
final class JumpIfOp extends VasterInstruction {
  final int targetPc;
  final String conditionVar;

  const JumpIfOp({required this.targetPc, required this.conditionVar})
      : super(InstructionOpcode.jumpIf);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'targetPc': targetPc,
        'conditionVar': conditionVar,
      };
}

/// Sets [registerName] to primitive/JSON [value].
final class SetRegisterOp extends VasterInstruction {
  final String registerName;
  final dynamic value;

  const SetRegisterOp({required this.registerName, required this.value})
      : super(InstructionOpcode.setRegister);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'registerName': registerName,
        'value': value,
      };
}

/// Extracts field [jsonKey] from JSON [sourceVar] into [targetVar].
final class JsonExtractOp extends VasterInstruction {
  final String sourceVar;
  final String jsonKey;
  final String targetVar;

  const JsonExtractOp({
    required this.sourceVar,
    required this.jsonKey,
    required this.targetVar,
  }) : super(InstructionOpcode.jsonExtract);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sourceVar': sourceVar,
        'jsonKey': jsonKey,
        'targetVar': targetVar,
      };
}

/// Concatenates multiple register variables into [targetVar].
final class ConcatRegisterOp extends VasterInstruction {
  final String targetVar;
  final List<String> sourceVars;

  const ConcatRegisterOp({required this.targetVar, required this.sourceVars})
      : super(InstructionOpcode.concatRegister);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'targetVar': targetVar,
        'sourceVars': sourceVars,
      };
}

/// Begins VFS snapshot transaction.
final class BeginTransactionOp extends VasterInstruction {
  const BeginTransactionOp() : super(InstructionOpcode.beginTransaction);

  @override
  Map<String, dynamic> toJson() => {'opcode': opcode.name};
}

/// Commits VFS transaction.
final class CommitOp extends VasterInstruction {
  const CommitOp() : super(InstructionOpcode.commit);

  @override
  Map<String, dynamic> toJson() => {'opcode': opcode.name};
}

/// Rolls back VFS filesystems to snapshot.
final class RollbackOp extends VasterInstruction {
  const RollbackOp() : super(InstructionOpcode.rollback);

  @override
  Map<String, dynamic> toJson() => {'opcode': opcode.name};
}

/// Selects active LLM model descriptor.
final class SelectModelOp extends VasterInstruction {
  final ModelDescriptor descriptor;

  const SelectModelOp({required this.descriptor})
      : super(InstructionOpcode.selectModel);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'descriptor': descriptor.toJson(),
      };
}

/// Yields VM runtime execution to pause for human interaction (approval, Q&A, review, input).
final class YieldHumanInteractionOp extends VasterInstruction {
  final HumanInteractionRequest request;

  const YieldHumanInteractionOp({required this.request})
      : super(InstructionOpcode.yieldHumanInteraction);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'request': request.toJson(),
      };
}

/// Pushes a stack frame and jumps to subroutine at [targetPc].
final class CallOp extends VasterInstruction {
  final String functionName;
  final int targetPc;
  final Map<String, String> arguments;
  final String? outputVar;

  const CallOp({
    required this.functionName,
    required this.targetPc,
    this.arguments = const {},
    this.outputVar,
  }) : super(InstructionOpcode.call);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'functionName': functionName,
        'targetPc': targetPc,
        if (arguments.isNotEmpty) 'arguments': arguments,
        if (outputVar != null) 'outputVar': outputVar,
      };
}

/// Pops the stack frame and returns execution to the caller return PC address.
final class ReturnSubroutineOp extends VasterInstruction {
  final String? returnRegister;

  const ReturnSubroutineOp({this.returnRegister})
      : super(InstructionOpcode.returnSubroutine);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        if (returnRegister != null) 'returnRegister': returnRegister,
      };
}

/// Creates a new model session in the VM's SessionManager.
final class CreateSessionOp extends VasterInstruction {
  final String sessionId;
  final ModelDescriptor? modelDescriptor;

  const CreateSessionOp({
    required this.sessionId,
    this.modelDescriptor,
  }) : super(InstructionOpcode.createSession);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sessionId': sessionId,
        if (modelDescriptor != null) 'modelDescriptor': modelDescriptor!.toJson(),
      };
}

/// Sets the active session context for subsequent PromptOp instructions.
final class SetSessionOp extends VasterInstruction {
  final String sessionId;

  const SetSessionOp({required this.sessionId})
      : super(InstructionOpcode.setSession);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sessionId': sessionId,
      };
}

/// Explicitly checks security policy authorization for [action] on [resource].
final class CheckPolicyOp extends VasterInstruction {
  final PolicyAction action;
  final String resource;

  const CheckPolicyOp({
    required this.action,
    required this.resource,
  }) : super(InstructionOpcode.checkPolicy);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'action': action.name,
        'resource': resource,
      };
}

/// Halts program execution.
final class HaltOp extends VasterInstruction {
  const HaltOp() : super(InstructionOpcode.halt);

  @override
  Map<String, dynamic> toJson() => {'opcode': opcode.name};
}
