import 'package:vaster_agent/vaster_agent.dart';
import 'human_interaction.dart';
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

/// One labeled destination of a [DecideOp] — a statically-known branch the
/// model may select.
class DecisionBranch {
  final String label;
  final String description;
  final int targetPc;

  const DecisionBranch({
    required this.label,
    required this.description,
    required this.targetPc,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'description': description,
        'targetPc': targetPc,
      };

  factory DecisionBranch.fromJson(Map<String, dynamic> json) {
    return DecisionBranch(
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
      targetPc: json['targetPc'] as int? ?? 0,
    );
  }
}

/// Sealed abstract class representing a low-level Vaster ISA instruction opcode.
sealed class VasterInstruction {
  final InstructionOpcode opcode;

  const VasterInstruction(this.opcode);

  Map<String, dynamic> toJson();

  factory VasterInstruction.fromJson(Map<String, dynamic> json) {
    final opStr = json['opcode'];
    if (opStr is! String) {
      throw const FormatException('Instruction map has no "opcode" field.');
    }
    final opcode = InstructionOpcode.parse(opStr);

    return switch (opcode) {
      InstructionOpcode.prompt => PromptOp(
          promptText: json['promptText'] as String? ?? '',
          outputVar: json['outputVar'] as String?,
          responseSchema: json['responseSchema'] == null
              ? null
              : Map<String, dynamic>.from(json['responseSchema'] as Map),
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
          timeoutMs: json['timeoutMs'] as int?,
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
          responseSchema: json['responseSchema'] == null
              ? null
              : Map<String, dynamic>.from(json['responseSchema'] as Map),
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
      InstructionOpcode.popMessage => PopMessageOp(
          agentId: json['agentId'] as String? ?? '',
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.forkSession => ForkSessionOp(
          sourceSessionId: json['sourceSessionId'] as String? ?? '',
          targetSessionId: json['targetSessionId'] as String? ?? '',
        ),
      InstructionOpcode.addContext => AddContextOp(
          regionId: json['regionId'] as String? ?? '',
          label: json['label'] as String? ?? '',
          text: json['text'] as String? ?? '',
          sourceVar: json['sourceVar'] as String?,
          className: json['className'] as String?,
          priority: json['priority'] as String?,
          lifetime: json['lifetime'] as String?,
          compressibility: json['compressibility'] as String?,
          pinned: json['pinned'] as bool? ?? false,
        ),
      InstructionOpcode.evictContext => EvictContextOp(
          regionId: json['regionId'] as String? ?? '',
          force: json['force'] as bool? ?? false,
        ),
      InstructionOpcode.unpinContext => UnpinContextOp(
          regionId: json['regionId'] as String? ?? '',
        ),
      InstructionOpcode.setContextPolicy => SetContextPolicyOp(
          regionId: json['regionId'] as String? ?? '',
          priority: json['priority'] as String?,
          pinned: json['pinned'] as bool?,
          compressibility: json['compressibility'] as String?,
          utility: (json['utility'] as num?)?.toDouble(),
        ),
      InstructionOpcode.compressContext => CompressContextOp(
          regionId: json['regionId'] as String?,
          targetTokens: json['targetTokens'] as int?,
          outputVar: json['outputVar'] as String?,
        ),
      InstructionOpcode.incrementRegister => IncrementRegisterOp(
          registerName: json['registerName'] as String? ?? '',
          delta: json['delta'] as num? ?? 1,
        ),
      InstructionOpcode.compareRegister => CompareRegisterOp(
          leftVar: json['leftVar'] as String? ?? '',
          operator: json['operator'] as String? ?? 'eq',
          rightVar: json['rightVar'] as String?,
          rightValue: json['rightValue'],
          targetVar: json['targetVar'] as String? ?? '',
        ),
      InstructionOpcode.pushErrorHandler => PushErrorHandlerOp(
          targetPc: json['targetPc'] as int? ?? 0,
          errorVar: json['errorVar'] as String? ?? '__error__',
        ),
      InstructionOpcode.popErrorHandler => const PopErrorHandlerOp(),
      InstructionOpcode.pinContext => PinContextOp(
          regionId: json['regionId'] as String? ?? '',
        ),
      InstructionOpcode.registerToolSet => RegisterToolSetOp(
          tools: (json['tools'] as List? ?? [])
              .map((t) => ToolDefinition.fromJson(Map<String, dynamic>.from(t as Map)))
              .toList(),
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
      InstructionOpcode.decide => DecideOp(
          prompt: json['prompt'] as String? ?? '',
          branches: (json['branches'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map((b) => DecisionBranch.fromJson(b))
              .toList(),
          outputVar: json['outputVar'] as String?,
          defaultLabel: json['defaultLabel'] as String?,
        ),
      InstructionOpcode.halt => const HaltOp(),
    };
  }
}

/// Prompts model and stores result in [outputVar].
final class PromptOp extends VasterInstruction {
  final String promptText;
  final String? outputVar;

  /// Optional JSON Schema constraining the model's output (typed return value).
  /// When set, backends supporting structured outputs guarantee [outputVar]
  /// holds JSON validating against this schema.
  final Map<String, dynamic>? responseSchema;

  const PromptOp({required this.promptText, this.outputVar, this.responseSchema})
      : super(InstructionOpcode.prompt);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'promptText': promptText,
        if (outputVar != null) 'outputVar': outputVar,
        if (responseSchema != null) 'responseSchema': responseSchema,
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

  /// Per-execution wall-clock limit enforced by the sandbox, when set.
  final int? timeoutMs;

  const RegisterSandboxOp({
    required this.sandboxId,
    this.language = SandboxLanguage.dart,
    this.timeoutMs,
  }) : super(InstructionOpcode.registerSandbox);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'sandboxId': sandboxId,
        'language': language.name,
        if (timeoutMs != null) 'timeoutMs': timeoutMs,
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

  /// Optional JSON Schema constraining the task's output (typed return value).
  final Map<String, dynamic>? responseSchema;

  const DispatchAgentTaskOp({
    required this.agentId,
    required this.taskPrompt,
    this.outputVar,
    this.responseSchema,
  }) : super(InstructionOpcode.dispatchAgentTask);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'agentId': agentId,
        'taskPrompt': taskPrompt,
        if (outputVar != null) 'outputVar': outputVar,
        if (responseSchema != null) 'responseSchema': responseSchema,
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

/// Pops next unread message for [agentId] into [outputVar].
final class PopMessageOp extends VasterInstruction {
  final String agentId;
  final String? outputVar;

  const PopMessageOp({
    required this.agentId,
    this.outputVar,
  }) : super(InstructionOpcode.popMessage);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'agentId': agentId,
        if (outputVar != null) 'outputVar': outputVar,
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

/// Adds a context region to the VM context heap. Content comes from [text]
/// or, when [sourceVar] is set, from that register at runtime.
///
/// Policy fields ([priority], [lifetime], [compressibility]) are nullable
/// enum names: null means "inherit from the region's context class"
/// ([className], resolved against the program-header class table).
final class AddContextOp extends VasterInstruction {
  final String regionId;
  final String label;
  final String text;
  final String? sourceVar;
  final String? className; // ContextClass name in the program's class table
  final String? priority; // ContextPriority name; null = inherit
  final String? lifetime; // ContextLifetime name; null = inherit
  final String? compressibility; // ContextCompressibility name; null = inherit
  final bool pinned;

  const AddContextOp({
    required this.regionId,
    required this.label,
    this.text = '',
    this.sourceVar,
    this.className,
    this.priority,
    this.lifetime,
    this.compressibility,
    this.pinned = false,
  }) : super(InstructionOpcode.addContext);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'regionId': regionId,
        'label': label,
        if (text.isNotEmpty) 'text': text,
        if (sourceVar != null) 'sourceVar': sourceVar,
        if (className != null) 'className': className,
        if (priority != null) 'priority': priority,
        if (lifetime != null) 'lifetime': lifetime,
        if (compressibility != null) 'compressibility': compressibility,
        'pinned': pinned,
      };
}

/// Removes a context region from the VM context heap.
final class EvictContextOp extends VasterInstruction {
  final String regionId;

  /// Evict even when the region is pinned.
  final bool force;

  const EvictContextOp({required this.regionId, this.force = false})
      : super(InstructionOpcode.evictContext);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'regionId': regionId,
        'force': force,
      };
}

/// Unpins a context region (and releases its cache hint).
final class UnpinContextOp extends VasterInstruction {
  final String regionId;

  const UnpinContextOp({required this.regionId})
      : super(InstructionOpcode.unpinContext);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'regionId': regionId,
      };
}

/// Updates a region's management policy in place (only non-null fields apply).
final class SetContextPolicyOp extends VasterInstruction {
  final String regionId;
  final String? priority; // ContextPriority name
  final bool? pinned;
  final String? compressibility; // ContextCompressibility name
  final double? utility;

  const SetContextPolicyOp({
    required this.regionId,
    this.priority,
    this.pinned,
    this.compressibility,
    this.utility,
  }) : super(InstructionOpcode.setContextPolicy);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'regionId': regionId,
        if (priority != null) 'priority': priority,
        if (pinned != null) 'pinned': pinned,
        if (compressibility != null) 'compressibility': compressibility,
        if (utility != null) 'utility': utility,
      };
}

/// Compresses context toward a token target. Null [regionId] compacts the
/// whole heap; null [targetTokens] uses 90% of the active model input budget.
/// [outputVar] receives the number of tokens freed.
final class CompressContextOp extends VasterInstruction {
  final String? regionId;
  final int? targetTokens;
  final String? outputVar;

  const CompressContextOp({this.regionId, this.targetTokens, this.outputVar})
      : super(InstructionOpcode.compressContext);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        if (regionId != null) 'regionId': regionId,
        if (targetTokens != null) 'targetTokens': targetTokens,
        if (outputVar != null) 'outputVar': outputVar,
      };
}

/// Registers a set of tools into the runtime environment.
final class RegisterToolSetOp extends VasterInstruction {
  final List<ToolDefinition> tools;

  const RegisterToolSetOp({required this.tools})
      : super(InstructionOpcode.registerToolSet);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'tools': tools.map((t) => t.toJson()).toList(),
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

/// Model-steered branch: the LLM selects one of [branches] and control
/// transfers to its `targetPc`. Always transfers — no fall-through.
///
/// Bounded agency: every destination is statically known, so analyzers can
/// enumerate the full decision surface of a program. When the model's answer
/// resolves to no branch label, [defaultLabel]'s branch is taken; with no
/// default the instruction traps (catchable by program-level error handlers).
/// The chosen label is written to [outputVar] and the model's rationale to
/// `${outputVar}_rationale` when [outputVar] is set.
final class DecideOp extends VasterInstruction {
  final String prompt;
  final List<DecisionBranch> branches;
  final String? outputVar;
  final String? defaultLabel;

  const DecideOp({
    required this.prompt,
    required this.branches,
    this.outputVar,
    this.defaultLabel,
  }) : super(InstructionOpcode.decide);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'prompt': prompt,
        'branches': branches.map((b) => b.toJson()).toList(),
        if (outputVar != null) 'outputVar': outputVar,
        if (defaultLabel != null) 'defaultLabel': defaultLabel,
      };
}

/// Sets [registerName] to primitive/JSON [value].
/// Adds [delta] to a numeric register (missing/non-numeric treated as 0).
final class IncrementRegisterOp extends VasterInstruction {
  final String registerName;
  final num delta;

  const IncrementRegisterOp({required this.registerName, this.delta = 1})
      : super(InstructionOpcode.incrementRegister);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'registerName': registerName,
        'delta': delta,
      };
}

/// Compares a register against another register or an immediate value and
/// writes the boolean result into [targetVar]. Operators:
/// `lt`, `le`, `gt`, `ge`, `eq`, `ne`. Numeric comparison when both sides
/// parse as numbers, string comparison otherwise.
final class CompareRegisterOp extends VasterInstruction {
  final String leftVar;
  final String operator;
  final String? rightVar;
  final dynamic rightValue;
  final String targetVar;

  const CompareRegisterOp({
    required this.leftVar,
    required this.operator,
    this.rightVar,
    this.rightValue,
    required this.targetVar,
  }) : super(InstructionOpcode.compareRegister);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'leftVar': leftVar,
        'operator': operator,
        if (rightVar != null) 'rightVar': rightVar,
        if (rightValue != null) 'rightValue': rightValue,
        'targetVar': targetVar,
      };
}

/// Installs an error handler: if any instruction throws while this handler is
/// the innermost one, the error message is written to [errorVar] and control
/// transfers to [targetPc] instead of trapping. Policy violations are NOT
/// catchable — they always trap.
final class PushErrorHandlerOp extends VasterInstruction {
  final int targetPc;
  final String errorVar;

  const PushErrorHandlerOp({required this.targetPc, this.errorVar = '__error__'})
      : super(InstructionOpcode.pushErrorHandler);

  @override
  Map<String, dynamic> toJson() => {
        'opcode': opcode.name,
        'targetPc': targetPc,
        'errorVar': errorVar,
      };
}

/// Uninstalls the innermost error handler (normal try-block exit).
final class PopErrorHandlerOp extends VasterInstruction {
  const PopErrorHandlerOp() : super(InstructionOpcode.popErrorHandler);

  @override
  Map<String, dynamic> toJson() => {'opcode': opcode.name};
}

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
