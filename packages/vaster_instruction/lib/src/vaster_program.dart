import 'vaster_instruction_base.dart';

/// Container class representing a compiled sequence of low-level Vaster ISA instructions (bytecode/program).
class VasterProgram {
  final String programName;
  final List<VasterInstruction> instructions;

  const VasterProgram({
    required this.programName,
    required this.instructions,
  });

  Map<String, dynamic> toJson() => {
        'programName': programName,
        'instructions': instructions.map((i) => i.toJson()).toList(),
      };

  factory VasterProgram.fromJson(Map<String, dynamic> json) {
    final name = json['programName'] as String? ?? 'vaster_program';
    final instRaw = json['instructions'] as List? ?? [];

    return VasterProgram(
      programName: name,
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
