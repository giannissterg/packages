import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main(List<String> args) async {
  print('======================================================================');
  print('    VASTER REAL LIVE MODEL EXAMPLE (Google AI Gemini REST / CLI)      ');
  print('======================================================================\n');

  final apiKey = Platform.environment['GEMINI_API_KEY'] ??
      Platform.environment['GOOGLE_AI_API_KEY'] ??
      (args.isNotEmpty && !args.first.startsWith('-') ? args.first : null);

  late final VasterModel liveModel;
  if (apiKey != null && apiKey.isNotEmpty) {
    print('🔑 Using Google AI REST API Key ($apiKey)');
    liveModel = GoogleAiVasterModel(
      apiKey: apiKey,
      targetModel: 'gemini-2.5-flash',
    );
  } else {
    print('⚡ No GEMINI_API_KEY provided in environment. Using live Gemini CLI backend!');
    liveModel = GeminiCliVasterModel(
      modelName: 'gemini-2.5-flash',
    );
  }

  const researcherRole = AgentRole(
    roleId: 'researcher',
    name: 'Senior AI Researcher',
    title: 'Lead Scientist',
    instruction: 'You analyze AI breakthroughs and return concise, insightful executive summaries.',
  );

  // Build Tree-Structured Provider AST
  final pipeline = Pipeline(
    spec: const PipelineSpec(name: 'real_google_ai_pipeline'),
    mounts: const [StorageMount(mountPrefix: '/workspace')],
    roles: const [researcherRole],
    children: [
      const WriteFile(
        path: '/workspace/query.txt',
        content: 'Explain the core architectural innovations of Google Antigravity AI agents.',
      ),
      const ReadFile(path: '/workspace/query.txt'),

      // Agent Scope Provider wrapping Task
      Agent(
        role: researcherRole,
        children: const [
          Task(prompt: 'Analyze the query at /workspace/query.txt and return a 2-paragraph executive report.'),
        ],
      ),

      const Output(),
    ],
  );

  print('┌─ COMPILING AST ────────────────────────────────────────────────┐');
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  print('  Pipeline Compiled: ${program.programName} (${program.instructions.length} instructions)\n');

  print('┌─ BOOTSTRAP VM & LIVE MODEL BACKEND ───────────────────────────┐');
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: liveModel,
      rootMountPath: '/workspace',
    ),
  );
  print('  VM initialized with model: ${liveModel.modelName}\n');

  print('┌─ EXECUTING PROGRAM LIVE ───────────────────────────────────────┐');
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget(maxDuration: const Duration(minutes: 2)),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);

  print('\n✅ Live Model Execution Finished!');
  print('  Status: ${state.status.name}');
  print('  Output Register Value:');
  print('  --------------------------------------------------------------');
  print(state.registers['__output__']);
  print('  --------------------------------------------------------------\n');

  await vm.shutdown();
}
