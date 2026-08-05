import 'dart:convert';

import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'session_snapshot.dart';

/// A suspended pipeline as one self-contained, versioned JSON document.
///
/// Everything a resume needs travels together: the program itself (VBC
/// bytes), the execution core ([VasterContinuation] — pc, registers, call
/// stack, pending HITL request), session histories, the context heap,
/// memory-mount files, and the consumed meters. Kill the process, move the
/// file, resume days later in a fresh VM.
///
/// The checkpoint composes each subsystem's own snapshot surface
/// (`ContextRegion.toJson`, `MemoryVasterFileSystem.exportFilesBase64`,
/// session history) — no subsystem knows this type exists (Rule 6), and
/// `vaster_continuation` stays the pure execution snapshot it always was.
///
/// ### What is NOT captured
/// - Disk mounts (they survive restarts by nature; only memory mounts ride).
/// - Live agent objects (agents are recreated on demand; their sessions —
///   the durable part — are captured and re-adopted on first dispatch).
/// - Cache hints (derived state, rebuilt from restored pinned regions).
final class MachineCheckpoint {
  static const int currentFormatVersion = 1;

  final int formatVersion;

  /// The program, base64(VBC) — a checkpoint without its program is a
  /// riddle, not an artifact.
  final String programVbcBase64;

  /// Execution core: pc, registers, call stack, pending HITL request.
  final VasterContinuation continuation;

  final List<SessionSnapshot> sessions;

  /// Serialized [ContextRegion]s of the VM-wide heap.
  final List<Map<String, dynamic>> contextRegions;

  /// mountPrefix → (path → base64 content), memory mounts only.
  final Map<String, Map<String, String>> memoryMounts;

  /// Program-registered tool definitions active at capture
  /// (`RegisterToolSetOp`).
  final List<Map<String, dynamic>> programToolSet;

  /// Program error-handler stack active at capture (`PushErrorHandlerOp`),
  /// innermost last.
  final List<Map<String, dynamic>> errorHandlers;

  /// The program-declared quota active at capture, with its consumed meters.
  final ResourceQuota quota;
  final int quotaConsumedTokens;
  final double quotaConsumedCost;
  final int quotaConsumedToolCalls;

  /// Host-budget consumption at capture (limits are the resuming host's
  /// decision; consumption is a fact of the run).
  final int budgetConsumedTokens;
  final double budgetConsumedCost;
  final Duration budgetConsumedDuration;

  final DateTime capturedAt;

  const MachineCheckpoint({
    this.formatVersion = currentFormatVersion,
    required this.programVbcBase64,
    required this.continuation,
    required this.sessions,
    required this.contextRegions,
    required this.memoryMounts,
    this.programToolSet = const [],
    this.errorHandlers = const [],
    required this.quota,
    required this.quotaConsumedTokens,
    required this.quotaConsumedCost,
    required this.quotaConsumedToolCalls,
    required this.budgetConsumedTokens,
    required this.budgetConsumedCost,
    required this.budgetConsumedDuration,
    required this.capturedAt,
  });

  /// Captures the whole machine from a live (runtime, vm) pair.
  ///
  /// Capture happens at instruction boundaries by construction — the natural
  /// points are a HITL pause ([RuntimeStatus.pausedForHuman]) or any stopped
  /// state; capturing a machine that is mid-`_execute` is a caller bug.
  factory MachineCheckpoint.capture({
    required VasterRuntime runtime,
    required VasterVirtualMachine vm,
    required VasterProgram program,
  }) {
    final state = runtime.state;
    return MachineCheckpoint(
      programVbcBase64: base64Encode(program.toBytes()),
      continuation: VasterContinuation(
        continuationId: 'ckpt_${state.pc}_${program.programName}',
        programName: program.programName,
        sessionId: runtime.activeSessionId,
        activeModelDescriptor: runtime.activeModelDescriptor,
        resumePc: state.pc,
        registers: Map<String, dynamic>.from(state.registers),
        callStack: [
          for (final frame in runtime.callStackSnapshot)
            StackFrame(
              functionName: frame.functionName,
              returnPc: frame.returnPc,
              outputVar: frame.outputVar,
            ),
        ],
        pendingRequest: runtime.pendingHumanRequest,
      ),
      sessions: SessionSnapshot.captureAll(vm),
      contextRegions: [
        for (final region in vm.contextManager.regions) region.toJson(),
      ],
      memoryMounts: {
        for (final entry in vm.fileSystemManager.mounts.entries)
          if (entry.value is MemoryVasterFileSystem)
            entry.key:
                (entry.value as MemoryVasterFileSystem).exportFilesBase64(),
      },
      programToolSet: [
        for (final def in runtime.programToolSet) def.toJson(),
      ],
      errorHandlers: [
        for (final h in runtime.errorHandlersSnapshot)
          {'targetPc': h.targetPc, 'errorVar': h.errorVar},
      ],
      quota: runtime.activeQuota,
      quotaConsumedTokens: runtime.quotaConsumedTokens,
      quotaConsumedCost: runtime.quotaConsumedCost,
      quotaConsumedToolCalls: runtime.quotaConsumedToolCalls,
      budgetConsumedTokens: runtime.budget.consumedTokens,
      budgetConsumedCost: runtime.budget.consumedCost,
      budgetConsumedDuration: runtime.budget.consumedDuration,
      capturedAt: DateTime.now(),
    );
  }

  /// The checkpointed program, decoded from its embedded VBC bytes.
  VasterProgram decodeProgram() =>
      VasterProgramBinary.fromBytes(base64Decode(programVbcBase64));

  /// Builds a host budget whose consumption continues from the checkpoint
  /// (no double-charge, no free ride). Limits are the resuming host's call.
  ExecutionBudget buildBudget({
    int? maxTokens,
    double? maxCost,
    Duration? maxDuration,
    DateTime? deadline,
  }) =>
      ExecutionBudget(
        maxTokens: maxTokens,
        maxCost: maxCost,
        maxDuration: maxDuration,
        deadline: deadline,
        initialConsumedTokens: budgetConsumedTokens,
        initialConsumedCost: budgetConsumedCost,
        initialConsumedDuration: budgetConsumedDuration,
      );

  /// Restores every subsystem into [vm] and returns a runtime primed to
  /// resume — without running it (callers who need to inspect first).
  ///
  /// [budget] defaults to [buildBudget] with no limits; pass your own to
  /// impose resume-time capacity (still built via [buildBudget] so the
  /// meters continue).
  Future<VasterRuntime> restoreRuntime({
    required VasterVirtualMachine vm,
    required ExecutionPolicy policy,
    required VasterScheduler scheduler,
    ExecutionBudget? budget,
  }) async {
    for (final session in sessions) {
      await session.restoreInto(vm);
    }
    for (final regionJson in contextRegions) {
      vm.contextManager.addRegion(ContextRegion.fromJson(regionJson));
    }
    for (final entry in memoryMounts.entries) {
      final existing = vm.fileSystemManager.mounts[entry.key];
      if (existing is MemoryVasterFileSystem) {
        existing.importFilesBase64(entry.value);
      } else {
        vm.mountFileSystem(
            entry.key, MemoryVasterFileSystem()..importFilesBase64(entry.value));
      }
    }

    final runtime = VasterRuntime(
      vm: vm,
      policy: policy,
      budget: budget ?? buildBudget(),
      scheduler: scheduler,
    );
    runtime.restoreQuota(
      quota,
      consumedTokens: quotaConsumedTokens,
      consumedCost: quotaConsumedCost,
      consumedToolCalls: quotaConsumedToolCalls,
    );
    return runtime;
  }

  /// One-shot resume: restore everything and continue execution, optionally
  /// answering the pending HITL request with [respond].
  Future<RuntimeState> resume({
    required VasterVirtualMachine vm,
    required ExecutionPolicy policy,
    required VasterScheduler scheduler,
    ExecutionBudget? budget,
    HumanInteractionResponse? respond,
  }) async {
    final runtime = await restoreRuntime(
        vm: vm, policy: policy, scheduler: scheduler, budget: budget);
    return runtime.restoreAndResume(
      continuation.resumePc,
      decodeProgram(),
      registers: continuation.registers,
      callStack: [
        for (final frame in continuation.callStack)
          ActivationRecord(
            functionName: frame.functionName,
            returnPc: frame.returnPc,
            outputVar: frame.outputVar,
          ),
      ],
      pendingRequest: continuation.pendingRequest,
      humanResponse: respond,
      activeSessionId: continuation.sessionId,
      activeModelDescriptor: continuation.activeModelDescriptor,
      programToolSet: [
        for (final def in programToolSet)
          ToolDefinition.fromJson(Map<String, dynamic>.from(def)),
      ],
      errorHandlers: [
        for (final h in errorHandlers)
          (
            targetPc: (h['targetPc'] as num).toInt(),
            errorVar: h['errorVar'] as String,
          ),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'programVbcBase64': programVbcBase64,
        'continuation': continuation.toJson(),
        'sessions': [for (final s in sessions) s.toJson()],
        'contextRegions': contextRegions,
        'memoryMounts': memoryMounts,
        if (programToolSet.isNotEmpty) 'programToolSet': programToolSet,
        if (errorHandlers.isNotEmpty) 'errorHandlers': errorHandlers,
        'quota': quota.toJson(),
        'quotaConsumedTokens': quotaConsumedTokens,
        'quotaConsumedCost': quotaConsumedCost,
        'quotaConsumedToolCalls': quotaConsumedToolCalls,
        'budgetConsumedTokens': budgetConsumedTokens,
        'budgetConsumedCost': budgetConsumedCost,
        'budgetConsumedDurationMs': budgetConsumedDuration.inMilliseconds,
        'capturedAt': capturedAt.toIso8601String(),
      };

  factory MachineCheckpoint.fromJson(Map<String, dynamic> json) {
    final version = (json['formatVersion'] as num?)?.toInt() ?? 0;
    if (version != currentFormatVersion) {
      throw FormatException(
          'Checkpoint format v$version is not supported by this build '
          '(speaks v$currentFormatVersion).');
    }
    return MachineCheckpoint(
      formatVersion: version,
      programVbcBase64: json['programVbcBase64'] as String,
      continuation: VasterContinuation.fromJson(
          Map<String, dynamic>.from(json['continuation'] as Map)),
      sessions: [
        for (final s in json['sessions'] as List? ?? const [])
          SessionSnapshot.fromJson(Map<String, dynamic>.from(s as Map)),
      ],
      contextRegions: [
        for (final r in json['contextRegions'] as List? ?? const [])
          Map<String, dynamic>.from(r as Map),
      ],
      memoryMounts: {
        for (final entry in (json['memoryMounts'] as Map? ?? const {}).entries)
          entry.key.toString(): {
            for (final f in (entry.value as Map).entries)
              f.key.toString(): f.value.toString(),
          },
      },
      programToolSet: [
        for (final t in json['programToolSet'] as List? ?? const [])
          Map<String, dynamic>.from(t as Map),
      ],
      errorHandlers: [
        for (final h in json['errorHandlers'] as List? ?? const [])
          Map<String, dynamic>.from(h as Map),
      ],
      quota: ResourceQuota.fromJson(
          Map<String, dynamic>.from(json['quota'] as Map)),
      quotaConsumedTokens: (json['quotaConsumedTokens'] as num?)?.toInt() ?? 0,
      quotaConsumedCost:
          (json['quotaConsumedCost'] as num?)?.toDouble() ?? 0.0,
      quotaConsumedToolCalls:
          (json['quotaConsumedToolCalls'] as num?)?.toInt() ?? 0,
      budgetConsumedTokens:
          (json['budgetConsumedTokens'] as num?)?.toInt() ?? 0,
      budgetConsumedCost:
          (json['budgetConsumedCost'] as num?)?.toDouble() ?? 0.0,
      budgetConsumedDuration: Duration(
          milliseconds:
              (json['budgetConsumedDurationMs'] as num?)?.toInt() ?? 0),
      capturedAt: DateTime.parse(json['capturedAt'] as String),
    );
  }
}
