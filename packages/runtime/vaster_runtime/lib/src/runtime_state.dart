import 'runtime_status.dart';

/// Active execution state record of a [VasterRuntime] executing a program.
class RuntimeState {
  /// Current Program Counter index (0-indexed).
  final int pc;

  /// Runtime execution status.
  final RuntimeStatus status;

  /// Register memory storing instruction variables (`r0`, `r1`, named variables).
  final Map<String, dynamic> registers;

  /// Error details if status is [RuntimeStatus.error].
  final String? errorDetails;

  const RuntimeState({required this.pc, required this.status, this.registers = const {}, this.errorDetails});

  RuntimeState copyWith({
    int? pc,
    RuntimeStatus? status,
    Map<String, dynamic>? registers,
    String? errorDetails,
  }) {
    return RuntimeState(
      pc: pc ?? this.pc,
      status: status ?? this.status,
      registers: registers ?? Map.from(this.registers),
      errorDetails: errorDetails ?? this.errorDetails,
    );
  }

  @override
  String toString() => 'RuntimeState(pc: $pc, status: ${status.name}, vars: ${registers.keys})';
}
