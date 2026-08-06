/// How an agent task ended — **sealed, carrying its data** (rules.md
/// Rule 2): exhaustive switches make new failure shapes impossible to
/// ignore, and retry/fallback decisions read types, not string prefixes.
///
/// Wire shape: every variant serializes as `{kind: <stable name>, ...}`;
/// [TaskOutcome.kind] is also what the dispatch ops write into the
/// sibling outcome register (the ISA never references this type —
/// registers carry the kind STRING, per Rule 1's handles-and-descriptors
/// law).
sealed class TaskOutcome {
  const TaskOutcome();

  /// Stable wire name of this variant.
  String get kind;

  /// Legacy projection (the `AgentOutput.isSuccess` bool this hierarchy
  /// retires — same move as `MachinePhase.asStatus`).
  bool get isSuccess => this is TaskCompleted;

  /// Human-readable failure detail, empty for success.
  String get detail;

  Map<String, dynamic> toJson() => {'kind': kind, ...payloadJson()};

  Map<String, dynamic> payloadJson();

  factory TaskOutcome.fromJson(Map<String, dynamic> json) =>
      switch (json['kind']) {
        'completed' => const TaskCompleted(),
        'model-failure' => TaskModelFailure(
            message: json['message'] as String? ?? '',
            transient: json['transient'] as bool? ?? false),
        'quota-exceeded' => TaskQuotaExceeded(
            resourceType: json['resourceType'] as String? ?? 'unknown',
            currentUsage: json['currentUsage'] as num? ?? 0,
            quotaLimit: json['quotaLimit'] as num? ?? 0,
            message: json['message'] as String? ?? ''),
        'cancelled' => TaskCancelled(message: json['message'] as String? ?? ''),
        'refused' => TaskRefused(reason: json['reason'] as String? ?? ''),
        'failure' => TaskFailure(
            error: json['error'] as String? ?? '',
            stackTrace: json['stackTrace'] as String?),
        _ => TaskFailure(error: 'unknown outcome kind "${json['kind']}"'),
      };
}

/// The task ran to completion; its product is the `AgentOutput`'s text
/// and usage.
final class TaskCompleted extends TaskOutcome {
  const TaskCompleted();
  @override
  String get kind => 'completed';
  @override
  String get detail => '';
  @override
  Map<String, dynamic> payloadJson() => const {};
}

/// The model call failed. [transient] carries the retry classification
/// (timeouts, connection resets, 408/429/5xx) so `Resilient` retries
/// what can heal and fails fast on what cannot.
final class TaskModelFailure extends TaskOutcome {
  final String message;
  final bool transient;
  const TaskModelFailure({required this.message, required this.transient});
  @override
  String get kind => 'model-failure';
  @override
  String get detail => message;
  @override
  Map<String, dynamic> payloadJson() =>
      {'message': message, 'transient': transient};
}

/// A resource quota tripped mid-task. Fields mirror
/// `QuotaExceededException` as plain data — this package deliberately
/// does not depend on `vaster_resources` (the contract stays a leaf);
/// the producer copies the fields at the catch site.
final class TaskQuotaExceeded extends TaskOutcome {
  final String resourceType; // tokens | tool_calls | deadline | subagent_depth
  final num currentUsage;
  final num quotaLimit;
  final String message;
  const TaskQuotaExceeded({
    required this.resourceType,
    required this.currentUsage,
    required this.quotaLimit,
    required this.message,
  });
  @override
  String get kind => 'quota-exceeded';
  @override
  String get detail => message;
  @override
  Map<String, dynamic> payloadJson() => {
        'resourceType': resourceType,
        'currentUsage': currentUsage,
        'quotaLimit': quotaLimit,
        'message': message,
      };
}

/// The caller cancelled the task (a real type end-to-end — cancellation
/// is a decision, not an error string).
final class TaskCancelled extends TaskOutcome {
  final String message;
  const TaskCancelled({required this.message});
  @override
  String get kind => 'cancelled';
  @override
  String get detail => message;
  @override
  Map<String, dynamic> payloadJson() => {'message': message};
}

/// The manager refused to run the task at all (agent unregistered,
/// paused) — nothing executed, nothing was spent.
final class TaskRefused extends TaskOutcome {
  final String reason;
  const TaskRefused({required this.reason});
  @override
  String get kind => 'refused';
  @override
  String get detail => reason;
  @override
  Map<String, dynamic> payloadJson() => {'reason': reason};
}

/// Unclassified failure — the honest catch-all, carrying the error and
/// stack instead of losing them. Every variant added later shrinks this
/// one's territory.
final class TaskFailure extends TaskOutcome {
  final String error;
  final String? stackTrace;
  const TaskFailure({required this.error, this.stackTrace});
  @override
  String get kind => 'failure';
  @override
  String get detail => error;
  @override
  Map<String, dynamic> payloadJson() =>
      {'error': error, if (stackTrace != null) 'stackTrace': stackTrace};
}
