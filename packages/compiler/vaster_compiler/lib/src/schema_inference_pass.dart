import 'package:vaster_instruction/vaster_instruction.dart';

/// Type-inference pass: derives `responseSchema` for model invocations from
/// downstream dataflow.
///
/// When a [PromptOp]/[DispatchAgentTaskOp] output register is consumed by
/// [JsonExtractOp]s, the extracted keys prove the program *requires* the model
/// to return a JSON object with those fields. This pass synthesizes the
/// corresponding JSON Schema and attaches it to the producing instruction, so
/// structured-output backends can *guarantee* what the program assumes.
///
/// Explicit schemas (from `Task.outputSchema` / `Prompt.outputSchema`) are
/// never overwritten — annotation wins over inference.
class SchemaInferencePass {
  const SchemaInferencePass();

  List<VasterInstruction> run(List<VasterInstruction> instructions) {
    // Producing instruction index per output register (last write wins per
    // linear order — matches runtime redefinition semantics).
    final producerByRegister = <String, int>{};
    for (var pc = 0; pc < instructions.length; pc++) {
      final inst = instructions[pc];
      final outputVar = switch (inst) {
        PromptOp(:final outputVar) => outputVar,
        DispatchAgentTaskOp(:final outputVar) => outputVar,
        _ => null,
      };
      if (outputVar != null) producerByRegister[outputVar] = pc;
    }

    // Keys extracted from each producer's output.
    final extractedKeys = <int, Set<String>>{};
    for (final inst in instructions) {
      if (inst is JsonExtractOp) {
        final producer = producerByRegister[inst.sourceVar];
        if (producer != null) {
          extractedKeys.putIfAbsent(producer, () => <String>{}).add(inst.jsonKey);
        }
      }
    }

    if (extractedKeys.isEmpty) return instructions;

    // Rewrite producers lacking an explicit schema.
    final out = List<VasterInstruction>.of(instructions);
    for (final entry in extractedKeys.entries) {
      final pc = entry.key;
      final schema = _synthesizeSchema(entry.value);
      final inst = out[pc];
      out[pc] = switch (inst) {
        PromptOp(responseSchema: null) => PromptOp(
          promptText: inst.promptText,
          outputVar: inst.outputVar,
          responseSchema: schema,
        ),
        DispatchAgentTaskOp(responseSchema: null) => DispatchAgentTaskOp(
          agentId: inst.agentId,
          taskPrompt: inst.taskPrompt,
          outputVar: inst.outputVar,
          responseSchema: schema,
        ),
        _ => inst, // explicit schema present — annotation wins
      };
    }
    return out;
  }

  Map<String, dynamic> _synthesizeSchema(Set<String> keys) {
    final sorted = keys.toList()..sort();
    return {
      'type': 'object',
      'properties': {
        for (final key in sorted) key: {'type': 'string'},
      },
      'required': sorted,
      'additionalProperties': false,
    };
  }
}
