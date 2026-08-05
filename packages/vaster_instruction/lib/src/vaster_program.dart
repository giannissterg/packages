import 'vaster_instruction_base.dart';

/// Container class representing a compiled sequence of low-level Vaster ISA instructions (bytecode/program).
class VasterProgram {
  final String programName;
  final List<VasterInstruction> instructions;

  /// Context class table declared by the program — **static header metadata**,
  /// carried as opaque JSON so the ISA stays decoupled from the context
  /// subsystem (the runtime parses it into a typed table at program load).
  /// Null means the runtime's default table applies. Class definitions are
  /// deliberately NOT instructions: mid-stream definition would make class
  /// resolution dynamically scoped.
  final Map<String, dynamic>? contextClasses;

  /// Register holding the program's declared result — header metadata
  /// replacing the legacy `__output__` register convention. Hosts read
  /// `registers[resultBinding]` after halt; null means the program declares
  /// no result.
  final String? resultBinding;

  const VasterProgram({
    required this.programName,
    required this.instructions,
    this.contextClasses,
    this.resultBinding,
  });

  /// The program header as one JSON map (what VBC v2 carries); null when
  /// every header field is absent.
  Map<String, dynamic>? get headerJson => contextClasses == null &&
          resultBinding == null
      ? null
      : {
          if (contextClasses != null) 'contextClasses': contextClasses,
          if (resultBinding != null) 'resultBinding': resultBinding,
        };

  Map<String, dynamic> toJson() => {
        'programName': programName,
        if (contextClasses != null) 'contextClasses': contextClasses,
        if (resultBinding != null) 'resultBinding': resultBinding,
        'instructions': instructions.map((i) => i.toJson()).toList(),
      };

  factory VasterProgram.fromJson(Map<String, dynamic> json) {
    final name = json['programName'] as String? ?? 'vaster_program';
    final instRaw = json['instructions'] as List? ?? [];

    return VasterProgram(
      programName: name,
      contextClasses: json['contextClasses'] != null
          ? Map<String, dynamic>.from(json['contextClasses'] as Map)
          : null,
      resultBinding: json['resultBinding'] as String?,
      instructions: instRaw
          .whereType<Map<String, dynamic>>()
          .map((i) => VasterInstruction.fromJson(i))
          .toList(),
    );
  }

  @override
  String toString() =>
      'VasterProgram("$programName", instructions: ${instructions.length})';
}
