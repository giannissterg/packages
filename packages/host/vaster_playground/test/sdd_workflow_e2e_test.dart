import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// The SDD flagship: spec.md → plan.md → review gate → parallel workstreams,
/// with markdown artifacts in the VFS as the coordination medium and the
/// phase TREE as the workflow's dependency structure.
void main() {
  const architect = AgentRole(
    roleId: 'architect',
    name: 'Architect',
    title: 'Architect',
    instruction: 'You write specifications.',
  );
  const lead = AgentRole(
    roleId: 'lead',
    name: 'Lead',
    title: 'Tech Lead',
    instruction: 'You write implementation plans.',
  );
  const backend = AgentRole(
    roleId: 'backend',
    name: 'Backend',
    title: 'Backend Engineer',
    instruction: 'You build services.',
  );
  const frontend = AgentRole(
    roleId: 'frontend',
    name: 'Frontend',
    title: 'Frontend Engineer',
    instruction: 'You build clients.',
  );
  const reviewer = AgentRole(
    roleId: 'reviewer',
    name: 'Reviewer',
    title: 'Staff Reviewer',
    instruction: 'You review artifacts.',
  );

  test('Specify → Plan → Review → Implement produces real markdown artifacts', () async {
    final model = FakeVasterModel(
      handler: (request) {
        final text = request.messages.last.text;
        if (text.contains('Choose exactly one')) {
          return ModelResponse(message: ChatMessage.model(jsonEncode({'choice': 'approve'})));
        }
        // Route on each phase's distinctive static prompt marker; workstream
        // markers first (their prompts embed the interpolated plan text).
        String reply;
        if (text.contains('Your workstream: the sync API service')) {
          reply = '# Backend\nImplemented the sync API endpoints.';
        } else if (text.contains('Your workstream: the sync UI client')) {
          reply = '# Frontend\nImplemented the sync settings screen.';
        } else if (text.contains('Write the release notes')) {
          reply = '# Release Notes\nTask sync shipped across both surfaces.';
        } else if (text.contains('Review the artifact')) {
          reply = '# Review\nThe plan is sound. APPROVE.';
        } else if (text.contains('Produce a concrete implementation plan')) {
          reply = '# Plan\n1. Sync API (backend)\n2. Sync UI (frontend)';
        } else if (text.contains('reviewable specification')) {
          reply = '# Spec: Task Sync\nUsers can sync tasks across devices.';
        } else {
          reply = 'ack';
        }
        return ModelResponse(message: ChatMessage.model(reply));
      },
    );

    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/workspace'),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    // Phases are siblings — the pipeline reads as the SDD checklist itself;
    // only conditionality nests (Implement exists only when approved).
    final pipeline = Pipeline(
      result: const Binding('release_notes'),
      name: 'sdd_flagship',
      roles: const [architect, lead, backend, frontend, reviewer],
      children: const [
        Specify(goal: 'Let users sync their tasks across devices.', agent: architect),
        Plan(agent: lead),
        Review(
          agent: reviewer,
          onApprove: [
            Implement(
              workstreams: [
                Workstream(
                  agent: backend,
                  focus: 'the sync API service',
                  output: Binding('backend_result'),
                  artifact: '/workspace/backend.md',
                ),
                Workstream(
                  agent: frontend,
                  focus: 'the sync UI client',
                  output: Binding('frontend_result'),
                  artifact: '/workspace/frontend.md',
                ),
              ],
              integrate: Task(
                agent: lead,
                prompt: Template([
                  'Write the release notes.\n',
                  r'Backend: ',
                  Binding('backend_result'),
                  '\n',
                  r'Frontend: ',
                  Binding('frontend_result'),
                ]),
                output: Binding('release_notes'),
              ),
            ),
          ],
          onRevise: [Prompt(Template.text('Log: the plan needs revision.'))],
        ),
      ],
    );

    final program = const BasicWorkflowCompiler().compile(pipeline);
    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.halted);

    // The artifacts are real markdown — never literal placeholders.
    Future<String> readArtifact(String path) => vm.fileSystemManager.resolveFileSystem(path).readText(path);
    final spec = await readArtifact('/workspace/spec.md');
    expect(spec, contains('# Spec: Task Sync'));
    final plan = await readArtifact('/workspace/plan.md');
    expect(plan, contains('# Plan'));
    final review = await readArtifact('/workspace/review.md');
    expect(review, contains('APPROVE'));
    final backendDoc = await readArtifact('/workspace/backend.md');
    expect(backendDoc, contains('sync API endpoints'));
    for (final doc in [spec, plan, review, backendDoc]) {
      expect(doc, isNot(contains(r'${')));
    }

    // Artifacts flowed BETWEEN phases: the planner read the spec text, the
    // workstreams read the plan text.
    final planRequest = model.recordedRequests.firstWhere(
      (r) => r.messages.last.text.contains('implementation plan'),
    );
    expect(planRequest.messages.last.text, contains('# Spec: Task Sync'));
    final backendRequest = model.recordedRequests.firstWhere(
      (r) => r.messages.last.text.contains('sync API'),
    );
    expect(backendRequest.messages.last.text, contains('# Plan'));

    // The verdict bound and the approve branch ran to the release notes.
    expect(state.registers['review_verdict'], equals('approve'));
    expect('${state.registers['release_notes']}', contains('# Release Notes'));

    await vm.shutdown();
  });

  test('Review(revise:) loops — reject, replan against the critique, approve', () async {
    var planRuns = 0;
    var verdicts = 0;
    final model = FakeVasterModel(
      handler: (request) {
        final text = request.messages.last.text;
        if (text.contains('Choose exactly one')) {
          verdicts++;
          return ModelResponse(
            message: ChatMessage.model(jsonEncode({'choice': verdicts == 1 ? 'revise' : 'approve'})),
          );
        }
        String reply;
        if (text.contains('Produce a concrete implementation plan')) {
          planRuns++;
          reply = '# Plan v$planRuns';
        } else if (text.contains('Review the artifact')) {
          reply = planRuns == 1
              ? '# Review\nMilestone order is contradictory. REVISE.'
              : '# Review\nContradiction resolved. APPROVE.';
        } else if (text.contains('reviewable specification')) {
          reply = '# Spec\nThe thing.';
        } else {
          reply = 'ack';
        }
        return ModelResponse(message: ChatMessage.model(reply));
      },
    );

    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/workspace'),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final program = const BasicWorkflowCompiler().compile(
      Pipeline(
        name: 'review_loop_e2e',
        roles: const [architect, lead, reviewer],
        children: const [
          Specify(goal: 'the thing', agent: architect),
          Plan(agent: lead),
          Review(
            agent: reviewer,
            revise: Plan(agent: lead, addressing: Binding('review')),
            maxRounds: 3,
            onApprove: [Prompt(Template.text('kick off implementation'))],
          ),
        ],
      ),
    );

    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.halted);

    expect(planRuns, equals(2), reason: 'initial plan + one revision');
    expect(verdicts, equals(2), reason: 'revise, then approve');
    expect(state.registers['review_verdict'], equals('approve'));

    // The revising planner saw the first review's critique.
    final revisionRequest = model.recordedRequests.firstWhere(
      (r) => r.messages.last.text.contains('address every blocking issue'),
    );
    expect(revisionRequest.messages.last.text, contains('Milestone order is contradictory'));

    // The approved continuation ran; the artifact is the revised plan.
    expect(
      model.recordedRequests.any((r) => r.messages.last.text.contains('kick off implementation')),
      isTrue,
    );
    final plan = await vm.fileSystemManager
        .resolveFileSystem('/workspace/plan.md')
        .readText('/workspace/plan.md');
    expect(plan, equals('# Plan v2'));
    await vm.shutdown();
  });

  test('a revise verdict takes the rework branch, not the workstreams', () async {
    final model = FakeVasterModel(
      handler: (request) {
        final text = request.messages.last.text;
        if (text.contains('Choose exactly one')) {
          return ModelResponse(message: ChatMessage.model(jsonEncode({'choice': 'revise'})));
        }
        return ModelResponse(message: ChatMessage.model('# Doc\ncontent'));
      },
    );
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/workspace'),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final program = const BasicWorkflowCompiler().compile(
      Pipeline(
        name: 'sdd_revise',
        roles: const [architect, lead, reviewer, backend],
        children: const [
          Specify(goal: 'a goal', agent: architect),
          Plan(agent: lead),
          Review(
            agent: reviewer,
            onApprove: [
              Implement(
                workstreams: [Workstream(agent: backend, focus: 'build it', output: Binding('built'))],
              ),
            ],
            onRevise: [Prompt(Template.text('Log: revision requested.'))],
          ),
        ],
      ),
    );

    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.halted);
    expect(state.registers['review_verdict'], equals('revise'));

    final prompts = model.recordedRequests.map((r) => r.messages.last.text);
    expect(prompts.any((p) => p.contains('revision requested')), isTrue);
    expect(
      prompts.any((p) => p.contains('Own it end to end')),
      isFalse,
      reason: 'the Implement phase must not run on a revise verdict',
    );
    await vm.shutdown();
  });
}
