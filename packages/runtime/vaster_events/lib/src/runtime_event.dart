import 'file_operation_type.dart';

/// Abstract sealed class representing an event generated during LLM VM runtime execution.
sealed class RuntimeEvent {
  /// Unique event identifier.
  final String eventId;

  /// Timestamp when event was emitted.
  final DateTime timestamp;

  /// Arbitrary event metadata.
  final Map<String, dynamic> metadata;

  RuntimeEvent({
    required this.eventId,
    DateTime? timestamp,
    this.metadata = const {},
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson();
}

/// Emitted when a model generation request starts.
final class ModelStartedEvent extends RuntimeEvent {
  final String sessionId;
  final String modelName;
  final int promptTokenCount;

  ModelStartedEvent({
    required super.eventId,
    required this.sessionId,
    required this.modelName,
    required this.promptTokenCount,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'model_started',
        'eventId': eventId,
        'sessionId': sessionId,
        'modelName': modelName,
        'promptTokenCount': promptTokenCount,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when model execution completes.
final class ModelFinishedEvent extends RuntimeEvent {
  final String sessionId;
  final String finishReason;
  final int totalTokens;
  final Duration executionDuration;

  ModelFinishedEvent({
    required super.eventId,
    required this.sessionId,
    required this.finishReason,
    required this.totalTokens,
    required this.executionDuration,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'model_finished',
        'eventId': eventId,
        'sessionId': sessionId,
        'finishReason': finishReason,
        'totalTokens': totalTokens,
        'executionDurationMs': executionDuration.inMilliseconds,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Per-call token/cost usage, emitted by the component that OWNS the model
/// call (the VM's prompt funnel, or the agent manager per task) — exactly one
/// event per call; charge-only sites never emit.
///
/// This package is dependency-free, so the full usage breakdown travels as
/// the [usage] JSON map (cache read/write, thoughts, source) alongside the
/// flattened headline numbers.
final class ModelUsageEvent extends RuntimeEvent {
  final String modelName;

  /// Which funnel emitted this: `vm_prompt` or `agent_task`.
  final String callSite;

  final int promptTokenCount;
  final int candidatesTokenCount;
  final int totalTokenCount;

  /// Monetary cost when known (wire-reported or catalog-computed).
  final double? costUsd;

  /// True when the numbers came from a length heuristic, not the wire.
  final bool estimated;

  /// Full `UsageMetadata.toJson()` payload.
  final Map<String, dynamic> usage;

  ModelUsageEvent({
    required super.eventId,
    required this.modelName,
    required this.callSite,
    required this.promptTokenCount,
    required this.candidatesTokenCount,
    required this.totalTokenCount,
    this.costUsd,
    required this.estimated,
    required this.usage,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'model_usage',
        'eventId': eventId,
        'modelName': modelName,
        'callSite': callSite,
        'promptTokenCount': promptTokenCount,
        'candidatesTokenCount': candidatesTokenCount,
        'totalTokenCount': totalTokenCount,
        if (costUsd != null) 'costUsd': costUsd,
        'estimated': estimated,
        'usage': usage,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a declared model fallback chain advances: [fromModel]
/// failed with a model-kind error and execution falls through to [toModel]
/// (REL-P3). One event per chain advance — a call that exhausts the whole
/// chain emits one event per edge, then fails with the last error.
final class ModelFallbackEvent extends RuntimeEvent {
  final String fromModel;
  final String toModel;

  /// Text of the failure that triggered the fallthrough.
  final String reason;

  ModelFallbackEvent({
    required super.eventId,
    required this.fromModel,
    required this.toModel,
    required this.reason,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'model_fallback',
        'eventId': eventId,
        'fromModel': fromModel,
        'toModel': toModel,
        'reason': reason,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a tool invocation is called by a model.
final class ToolCalledEvent extends RuntimeEvent {
  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;

  ToolCalledEvent({
    required super.eventId,
    required this.callId,
    required this.toolName,
    required this.arguments,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_called',
        'eventId': eventId,
        'callId': callId,
        'toolName': toolName,
        'arguments': arguments,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a tool execution completes.
final class ToolFinishedEvent extends RuntimeEvent {
  final String callId;
  final String toolName;
  final bool isError;
  final Duration executionDuration;

  ToolFinishedEvent({
    required super.eventId,
    required this.callId,
    required this.toolName,
    required this.isError,
    required this.executionDuration,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_finished',
        'eventId': eventId,
        'callId': callId,
        'toolName': toolName,
        'isError': isError,
        'executionDurationMs': executionDuration.inMilliseconds,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted on virtual filesystem operations.
final class FileOperationEvent extends RuntimeEvent {
  final FileOperationType operation;
  final String path;
  final int sizeBytes;

  FileOperationEvent({
    required super.eventId,
    required this.operation,
    required this.path,
    required this.sizeBytes,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'file_operation',
        'eventId': eventId,
        'operation': operation.name,
        'path': path,
        'sizeBytes': sizeBytes,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when context regions are evicted from the heap.
final class ContextEvictedEvent extends RuntimeEvent {
  final List<String> evictedRegionIds;
  final int tokensFreed;

  ContextEvictedEvent({
    required super.eventId,
    required this.evictedRegionIds,
    required this.tokensFreed,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'context_evicted',
        'eventId': eventId,
        'evictedRegionIds': evictedRegionIds,
        'tokensFreed': tokensFreed,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a context region is compressed under budget pressure or by
/// explicit compaction.
final class ContextCompressedEvent extends RuntimeEvent {
  final String regionId;
  final int tokensBefore;
  final int tokensAfter;
  final String compressorId;
  final bool lossy;

  ContextCompressedEvent({
    required super.eventId,
    required this.regionId,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.compressorId,
    required this.lossy,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'context_compressed',
        'eventId': eventId,
        'regionId': regionId,
        'tokensBefore': tokensBefore,
        'tokensAfter': tokensAfter,
        'compressorId': compressorId,
        'lossy': lossy,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when an isolated code sandbox completes execution.
final class SandboxExecutedEvent extends RuntimeEvent {
  final String sandboxId;
  final String language;
  final int exitCode;
  final Duration executionDuration;

  SandboxExecutedEvent({
    required super.eventId,
    required this.sandboxId,
    required this.language,
    required this.exitCode,
    required this.executionDuration,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'sandbox_executed',
        'eventId': eventId,
        'sandboxId': sandboxId,
        'language': language,
        'exitCode': exitCode,
        'executionDurationMs': executionDuration.inMilliseconds,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted for non-fatal runtime conditions worth surfacing (e.g. an
/// unresolved `${...}` interpolation reference left verbatim).
final class RuntimeWarningEvent extends RuntimeEvent {
  /// Stable machine-readable code (e.g. `unresolved_interpolation`).
  final String code;
  final String message;
  final int pc;

  RuntimeWarningEvent({
    required super.eventId,
    required this.code,
    required this.message,
    required this.pc,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'runtime_warning',
        'eventId': eventId,
        'code': code,
        'message': message,
        'pc': pc,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when the model resolves a DecideOp — the audit trail of every
/// point where the model steered control flow.
final class DecisionMadeEvent extends RuntimeEvent {
  final String chosenLabel;
  final String? rationale;
  final int branchCount;
  final int targetPc;

  /// True when the model's answer did not resolve to a branch label and the
  /// instruction's default branch was taken instead.
  final bool usedDefault;

  DecisionMadeEvent({
    required super.eventId,
    required this.chosenLabel,
    this.rationale,
    required this.branchCount,
    required this.targetPc,
    required this.usedDefault,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'decision_made',
        'eventId': eventId,
        'chosenLabel': chosenLabel,
        if (rationale != null) 'rationale': rationale,
        'branchCount': branchCount,
        'targetPc': targetPc,
        'usedDefault': usedDefault,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when runtime execution yields and pauses waiting for human interaction.
final class HumanInteractionRequiredEvent extends RuntimeEvent {
  /// JSON payload of the interaction request (`HumanInteractionRequest.toJson`
  /// shape). Telemetry is passive and broadcast-only, so it carries the
  /// serialized form rather than a typed reference into the ISA layer.
  final Map<String, dynamic> request;

  HumanInteractionRequiredEvent({
    required super.eventId,
    required Map<String, dynamic> request,
    super.timestamp,
    super.metadata,
  }) : request = Map.unmodifiable(request);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'human_interaction_required',
        'eventId': eventId,
        'request': request,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a new model session is created in the VM.
final class SessionCreatedEvent extends RuntimeEvent {
  final String sessionId;
  final String modelName;

  SessionCreatedEvent({
    required super.eventId,
    required this.sessionId,
    required this.modelName,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'session_created',
        'eventId': eventId,
        'sessionId': sessionId,
        'modelName': modelName,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Emitted when a security policy evaluation is performed by the PolicyEngine.
final class PolicyEvaluatedEvent extends RuntimeEvent {
  final String policyId;
  final String action;
  final String resource;
  final String decision;
  final String reason;

  PolicyEvaluatedEvent({
    required super.eventId,
    required this.policyId,
    required this.action,
    required this.resource,
    required this.decision,
    required this.reason,
    super.timestamp,
    super.metadata,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'policy_evaluated',
        'eventId': eventId,
        'policyId': policyId,
        'action': action,
        'resource': resource,
        'decision': decision,
        'reason': reason,
        'timestamp': timestamp.toIso8601String(),
      };
}
