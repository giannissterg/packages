/// One program error-handler frame (`PushErrorHandlerOp`), innermost last.
///
/// Previously an anonymous record on the runtime — unserializable by name
/// and invisible to carriers, which is exactly how it escaped the first
/// checkpoint implementation.
final class ErrorHandlerFrame {
  final int targetPc;
  final String errorVar;

  const ErrorHandlerFrame({required this.targetPc, required this.errorVar});

  Map<String, dynamic> toJson() => {'targetPc': targetPc, 'errorVar': errorVar};

  factory ErrorHandlerFrame.fromJson(Map<String, dynamic> json) =>
      ErrorHandlerFrame(
        targetPc: (json['targetPc'] as num).toInt(),
        errorVar: json['errorVar'] as String,
      );
}
