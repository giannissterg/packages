import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Spec-driven development as a declarative phase tree: a goal becomes
/// spec.md, the spec becomes plan.md, a review gates the hand-off, and the
/// plan fans out into parallel workstreams — with the markdown artifacts in
/// the VFS as the coordination medium between agents.
Future<void> main() async {
  const architect = AgentRole(
      roleId: 'architect', name: 'Architect', title: 'Principal Architect',
      instruction: 'You write precise, reviewable specifications.');
  const lead = AgentRole(
      roleId: 'lead', name: 'Lead', title: 'Tech Lead',
      instruction: 'You turn specs into concrete implementation plans.');
  const backend = AgentRole(
      roleId: 'backend', name: 'Backend', title: 'Backend Engineer',
      instruction: 'You implement services.');
  const frontend = AgentRole(
      roleId: 'frontend', name: 'Frontend', title: 'Frontend Engineer',
      instruction: 'You implement clients.');
  const reviewer = AgentRole(
      roleId: 'reviewer', name: 'Reviewer', title: 'Staff Reviewer',
      instruction: 'You review artifacts rigorously.');

  final model = FakeVasterModel(handler: (request) {
    final text = request.messages.last.text;
    if (text.contains('Choose exactly one')) {
      return ModelResponse(
          message: ChatMessage.model(jsonEncode(
              {'choice': 'approve', 'rationale': 'The plan is complete.'})));
    }
    String reply;
    if (text.contains('Your workstream: the export API')) {
      reply = '# Backend Deliverable\nExport API with CSV and JSON encoders.';
    } else if (text.contains('Your workstream: the export dialog')) {
      reply = '# Frontend Deliverable\nExport dialog with format selection.';
    } else if (text.contains('Write the release notes')) {
      reply = '# Release Notes\nUsers can now export their data.';
    } else if (text.contains('Review the artifact')) {
      reply = '# Review\nMilestones are ordered and testable. APPROVE.';
    } else if (text.contains('Produce a concrete implementation plan')) {
      reply = '# Plan\n1. Export API (backend)\n2. Export dialog (frontend)';
    } else if (text.contains('reviewable specification')) {
      reply = '# Spec: Data Export\nUsers export their data as CSV or JSON.';
    } else {
      reply = 'ack';
    }
    return ModelResponse(message: ChatMessage.model(reply));
  });

  // Phases are siblings — the pipeline reads as the SDD checklist itself;
  // only conditionality nests (Implement exists only when approved).
  final pipeline = Pipeline(
    name: 'sdd_data_export',
    roles: const [architect, lead, backend, frontend, reviewer],
    children: const [
      Specify(
        goal: 'Let users export their data as CSV or JSON.',
        agent: architect,
      ),
      Plan(agent: lead),
      Review(
        agent: reviewer,
        onApprove: [
          Implement(
            workstreams: [
              Workstream(
                  agent: backend,
                  focus: 'the export API service',
                  output: 'backend_result',
                  artifact: '/workspace/deliverables/backend.md'),
              Workstream(
                  agent: frontend,
                  focus: 'the export dialog UI',
                  output: 'frontend_result',
                  artifact: '/workspace/deliverables/frontend.md'),
            ],
            integrate: Task(
              agent: lead,
              prompt: 'Write the release notes.\n'
                  r'Backend: ${backend_result}'
                  '\n'
                  r'Frontend: ${frontend_result}',
              output: 'release_notes',
            ),
          ),
          Output(from: 'release_notes'),
        ],
        onRevise: [Prompt('Log: plan sent back for revision.')],
      ),
    ],
  );

  final program = const BasicWorkflowCompiler().compile(pipeline);
  final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/workspace'));
  vm.eventBus.on<DecisionMadeEvent>().listen((event) => stdout.writeln(
      '[verdict] ${event.chosenLabel} — ${event.rationale ?? ''}'));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  await Future<void>.delayed(Duration.zero);

  stdout.writeln('\nstatus  : ${state.status.name}');
  for (final path in [
    '/workspace/spec.md',
    '/workspace/plan.md',
    '/workspace/review.md',
    '/workspace/deliverables/backend.md',
  ]) {
    final content =
        await vm.fileSystemManager.resolveFileSystem(path).readText(path);
    stdout.writeln('\n── $path ──\n${content.split('\n').first}');
  }
  stdout.writeln('\noutput  : ${state.registers['__output__']}');
  await vm.shutdown();
}
