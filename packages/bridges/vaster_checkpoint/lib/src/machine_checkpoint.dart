import 'dart:convert';

import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_filesystem_local/vaster_filesystem_local.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_policy/vaster_policy.dart';
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
  static const int currentFormatVersion = 2;

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

  /// mountPrefix → host disk path for disk-backed mounts. The FILES survive
  /// restarts by nature, but the mount TABLE is machine state — without it a
  /// resumed program traps resolving a prefix its pre-suspension MountFsOp
  /// had established (found by the first real-backend prove-it run).
  final Map<String, String> diskMounts;

  /// Open VFS transaction frames, outermost first — one
  /// `{mountPrefix: {path: base64}}` map per frame (GAP-1). A checkpoint
  /// taken inside a `Transaction` (the default around every `Task` since
  /// REL-P4) must resume with rollback protection intact — dropping the
  /// frames silently commits the abandoned transaction by loss.
  final List<Map<String, Map<String, String>>> openTransactions;

  /// agentId → serialized [AgentMessage]s, read/unread state included.
  /// Undelivered actor messages are durable state (found by the
  /// machine-state review: a message sent before suspension was lost).
  final Map<String, List<Map<String, dynamic>>> messageInboxes;

  /// Host-budget consumption at capture (limits are the resuming host's
  /// decision; consumption is a fact of the run). Everything machine-owned —
  /// registers, call stack, ambient context, HITL state, the program quota —
  /// rides inside [continuation]'s machine snapshot and is NOT enumerated
  /// here: the checkpoint cannot forget machine state it never lists.
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
    this.diskMounts = const {},
    this.openTransactions = const [],
    this.messageInboxes = const {},
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
    final machineState = runtime.captureSnapshot();
    return MachineCheckpoint(
      programVbcBase64: base64Encode(program.toBytes()),
      continuation: VasterContinuation(
        continuationId: 'ckpt_${machineState.pc}_${program.programName}',
        programName: program.programName,
        machineState: machineState,
      ),
      sessions: SessionSnapshot.captureAll(vm),
      contextRegions: [
        for (final region in vm.contextManager.regions) region.toJson(),
      ],
      // Every filesystem exports through the CONTRACT (Rule 8) — no
      // downcast, so a third implementation is captured, not silently
      // dropped. Backends whose bytes live outside the process return an
      // empty map and ride `diskMounts` instead.
      memoryMounts: {
        for (final entry in vm.fileSystemManager.mounts.entries)
          if (entry.value.exportFilesBase64() case final files
              when files.isNotEmpty)
            entry.key: files,
      },
      diskMounts: {
        for (final entry in vm.fileSystemManager.mounts.entries)
          if (entry.value is LocalVasterFileSystem)
            entry.key:
                (entry.value as LocalVasterFileSystem).rootDirectory.path,
      },
      openTransactions: vm.fileSystemManager.exportTransactions(),
      messageInboxes: vm.messagingHub.exportInboxes(),
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
      // Import through the contract into whatever is mounted; only the
      // MISSING-mount case constructs a filesystem, and memory is the
      // honest default for content that rode the checkpoint as bytes.
      final existing = vm.fileSystemManager.mounts[entry.key];
      if (existing != null) {
        existing.importFilesBase64(entry.value);
      } else {
        vm.mountFileSystem(
            entry.key, MemoryVasterFileSystem()..importFilesBase64(entry.value));
      }
    }

    for (final entry in diskMounts.entries) {
      if (vm.fileSystemManager.mounts[entry.key] == null) {
        vm.mountFileSystem(entry.key,
            LocalVasterFileSystem(entry.value, mountPrefix: entry.key));
      }
    }
    if (openTransactions.isNotEmpty) {
      vm.fileSystemManager.importTransactions(openTransactions);
    }
    if (messageInboxes.isNotEmpty) {
      vm.messagingHub.importInboxes(messageInboxes);
    }

    return VasterRuntime(
      vm: vm,
      policy: policy,
      budget: budget ?? buildBudget(),
      scheduler: scheduler,
    );
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
    return resumeWith(runtime, respond: respond);
  }

  /// Continues execution on a runtime obtained from [restoreRuntime] —
  /// split out so hosts can attach tracers/observers before resuming.
  Future<RuntimeState> resumeWith(
    VasterRuntime runtime, {
    HumanInteractionResponse? respond,
  }) =>
      runtime.restoreAndResume(
        continuation.machineState,
        decodeProgram(),
        humanResponse: respond,
      );

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'programVbcBase64': programVbcBase64,
        'continuation': continuation.toJson(),
        'sessions': [for (final s in sessions) s.toJson()],
        'contextRegions': contextRegions,
        'memoryMounts': memoryMounts,
        if (diskMounts.isNotEmpty) 'diskMounts': diskMounts,
        // Emitted only when frames are open: pre-GAP-1 checkpoints stay
        // byte-identical.
        if (openTransactions.isNotEmpty) 'openTransactions': openTransactions,
        if (messageInboxes.isNotEmpty) 'messageInboxes': messageInboxes,
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
      diskMounts: {
        for (final entry in (json['diskMounts'] as Map? ?? const {}).entries)
          entry.key.toString(): entry.value.toString(),
      },
      openTransactions: [
        for (final frame in json['openTransactions'] as List? ?? const [])
          {
            for (final entry in (frame as Map).entries)
              entry.key.toString(): {
                for (final f in (entry.value as Map).entries)
                  f.key.toString(): f.value.toString(),
              },
          },
      ],
      messageInboxes: {
        for (final entry
            in (json['messageInboxes'] as Map? ?? const {}).entries)
          entry.key.toString(): [
            for (final m in entry.value as List)
              Map<String, dynamic>.from(m as Map),
          ],
      },
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
