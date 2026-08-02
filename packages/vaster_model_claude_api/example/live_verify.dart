// ignore_for_file: avoid_print
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';

/// Live end-to-end verification of the compiler-level Claude backend:
/// 1. plain typed generation with exact usage
/// 2. tool-calling ABI round-trip (tool_use -> tool_result -> final answer)
/// 3. structured outputs (schema-guaranteed JSON return value)
Future<void> main() async {
  final model = ClaudeApiVasterModel();

  // ── 1. Plain generation ────────────────────────────────────────────────
  print('── 1. plain generation ──');
  final r1 = await model.generate(ModelRequest(
    messages: [ChatMessage.user('Reply with exactly one word: pong')],
    generationConfig: const GenerationConfig(maxOutputTokens: 2000),
  ));
  print('text   : ${r1.text.trim()}');
  print('finish : ${r1.finishReason.name}');
  print('usage  : ${r1.usage}');

  // ── 2. Tool-calling ABI round-trip ─────────────────────────────────────
  print('\n── 2. tool ABI round-trip ──');
  const tool = ToolDefinition(
    name: 'read_file',
    description:
        'Read a file from the Vaster virtual filesystem. Call this when you '
        'need file contents.',
    parametersSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute VFS path'},
      },
      'required': ['path'],
    },
  );

  final turn1 = await model.generate(ModelRequest(
    systemInstruction:
        ChatMessage.system('Use the read_file tool to answer questions about files.'),
    messages: [ChatMessage.user('What does /mem/greeting.txt contain?')],
    tools: const [tool],
    generationConfig: const GenerationConfig(maxOutputTokens: 2000),
  ));
  final call = turn1.functionCalls.firstOrNull;
  if (call == null) {
    print('!! model did not emit a tool call (finish=${turn1.finishReason.name})');
  } else {
    print('tool_use: ${call.name}(${call.arguments}) [${call.callId}]');

    // Execute the "tool" (simulated VFS) and send the typed result back.
    final turn2 = await model.generate(ModelRequest(
      systemInstruction:
          ChatMessage.system('Use the read_file tool to answer questions about files.'),
      messages: [
        ChatMessage.user('What does /mem/greeting.txt contain?'),
        ChatMessage(role: Role.model, parts: [call]),
        ChatMessage.toolResponse(
            call.callId, call.name, {'content': 'hello from the Vaster VFS'}),
      ],
      tools: const [tool],
      generationConfig: const GenerationConfig(maxOutputTokens: 2000),
    ));
    print('final  : ${turn2.text.trim()}');
    print('finish : ${turn2.finishReason.name}  usage: ${turn2.usage}');
  }

  // ── 3. Structured outputs (typed return value) ─────────────────────────
  print('\n── 3. structured outputs ──');
  final r3 = await model.generate(ModelRequest(
    messages: [
      ChatMessage.user(
          'Extract: "Deploy service alpha to region eu-west-1 at priority 3"'),
    ],
    generationConfig: const GenerationConfig(
      maxOutputTokens: 2000,
      responseSchema: {
        'type': 'object',
        'properties': {
          'service': {'type': 'string'},
          'region': {'type': 'string'},
          'priority': {'type': 'integer'},
        },
        'required': ['service', 'region', 'priority'],
        'additionalProperties': false,
      },
    ),
  ));
  print('json   : ${r3.text.trim()}');
  print('finish : ${r3.finishReason.name}  usage: ${r3.usage}');

  print('\n✓ live verification complete');
}
