/// One program error-handler frame (`PushErrorHandlerOp`), innermost last.
///
/// Previously an anonymous record on the runtime — unserializable by name
/// and invisible to carriers, which is exactly how it escaped the first
/// checkpoint implementation.
///
/// [transactionDepth] and [effectScopeDepth] record how many VFS
/// transactions and effect scopes were open when this handler was pushed —
/// the unwind targets when a failure lands here (REL-P4): open transactions
/// above the mark roll back, effect scopes above it merge outward. A
/// handler that doesn't know these depths cannot clean up what the failed
/// region abandoned.
final class ErrorHandlerFrame {
  final int targetPc;
  final String errorVar;
  final int transactionDepth;
  final int effectScopeDepth;

  const ErrorHandlerFrame({
    required this.targetPc,
    required this.errorVar,
    this.transactionDepth = 0,
    this.effectScopeDepth = 0,
  });

  Map<String, dynamic> toJson() => {
        'targetPc': targetPc,
        'errorVar': errorVar,
        // Emitted only when non-zero: pre-P4 snapshots stay byte-identical.
        if (transactionDepth != 0) 'transactionDepth': transactionDepth,
        if (effectScopeDepth != 0) 'effectScopeDepth': effectScopeDepth,
      };

  factory ErrorHandlerFrame.fromJson(Map<String, dynamic> json) => ErrorHandlerFrame(
        targetPc: (json['targetPc'] as num).toInt(),
        errorVar: json['errorVar'] as String,
        transactionDepth: (json['transactionDepth'] as num?)?.toInt() ?? 0,
        effectScopeDepth: (json['effectScopeDepth'] as num?)?.toInt() ?? 0,
      );
}
