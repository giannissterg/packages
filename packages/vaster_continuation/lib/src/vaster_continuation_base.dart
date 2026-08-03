import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model/vaster_model.dart';

/// Single activation record / stack frame on the Vaster VM call stack.
///
/// Mirrors the runtime's live activation record field-for-field so that a
/// suspended machine round-trips faithfully: [returnPc] is where control
/// resumes when the subroutine returns, and [outputVar] is the register its
/// return value lands in.
class StackFrame {
  final String functionName;
  final int returnPc;

  /// Register the subroutine's return value is written into, if any.
  final String? outputVar;

  final Map<String, dynamic> localRegisters;

  const StackFrame({
    required this.functionName,
    required this.returnPc,
    this.outputVar,
    this.localRegisters = const {},
  });

  Map<String, dynamic> toJson() => {
        'functionName': functionName,
        'returnPc': returnPc,
        if (outputVar != null) 'outputVar': outputVar,
        if (localRegisters.isNotEmpty) 'localRegisters': localRegisters,
      };

  factory StackFrame.fromJson(Map<String, dynamic> json) {
    return StackFrame(
      functionName: json['functionName'] as String? ?? 'anonymous',
      returnPc: json['returnPc'] as int? ?? 0,
      outputVar: json['outputVar'] as String?,
      localRegisters: Map<String, dynamic>.from(json['localRegisters'] as Map? ?? {}),
    );
  }
}

/// First-class, serializable snapshot of Vaster VM execution state at a yield/trap boundary.
///
/// Unifies the LLM VM Triad:
/// 1. Bytecode execution state ([resumePc], [registers], [callStack]).
/// 2. Conversational context state ([sessionId]).
/// 3. Active compute processor descriptor ([activeModelDescriptor]).
class VasterContinuation {
  final String continuationId;
  final String programName;
  final String? sessionId;
  final ModelDescriptor? activeModelDescriptor;
  final int resumePc;
  final Map<String, dynamic> registers;
  final List<StackFrame> callStack;
  final HumanInteractionRequest? pendingRequest;
  final DateTime suspendedAt;

  VasterContinuation({
    required this.continuationId,
    required this.programName,
    this.sessionId,
    this.activeModelDescriptor,
    required this.resumePc,
    required this.registers,
    this.callStack = const [],
    this.pendingRequest,
    DateTime? suspendedAt,
  }) : suspendedAt = suspendedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'continuationId': continuationId,
        'programName': programName,
        if (sessionId != null) 'sessionId': sessionId,
        if (activeModelDescriptor != null)
          'activeModelDescriptor': activeModelDescriptor!.toJson(),
        'resumePc': resumePc,
        'registers': registers,
        if (callStack.isNotEmpty)
          'callStack': callStack.map((f) => f.toJson()).toList(),
        if (pendingRequest != null) 'pendingRequest': pendingRequest!.toJson(),
        'suspendedAt': suspendedAt.toIso8601String(),
      };

  factory VasterContinuation.fromJson(Map<String, dynamic> json) {
    return VasterContinuation(
      continuationId: json['continuationId'] as String? ?? '',
      programName: json['programName'] as String? ?? '',
      sessionId: json['sessionId'] as String?,
      activeModelDescriptor: json['activeModelDescriptor'] != null
          ? ModelDescriptor.fromJson(json['activeModelDescriptor'] as Map<String, dynamic>)
          : null,
      resumePc: json['resumePc'] as int? ?? 0,
      registers: Map<String, dynamic>.from(json['registers'] as Map? ?? {}),
      callStack: (json['callStack'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((f) => StackFrame.fromJson(f))
          .toList(),
      pendingRequest: json['pendingRequest'] != null
          ? HumanInteractionRequest.fromJson(json['pendingRequest'] as Map<String, dynamic>)
          : null,
      suspendedAt: DateTime.tryParse(json['suspendedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
