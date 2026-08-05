import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// The coordination library in one runnable story: an incident-response desk.
///
/// AgentTeam provisions the team once · Knowledge grounds the whole desk in
/// the runbook (structural lifetime) · ContextBudget bounds the heap ·
/// Router triages the incident to the right responder · FanOut investigates
/// two angles in parallel and synthesizes · RefineLoop polishes the customer
/// reply until the editor accepts · Produce emits a schema-typed incident
/// report artifact.
Future<void> main() async {
  const triager = AgentRole(
      roleId: 'triager', name: 'Triager', title: 'Incident Triager',
      instruction: 'You route incidents to the right responder.');
  const sre = AgentRole(
      roleId: 'sre', name: 'SRE', title: 'Site Reliability Engineer',
      instruction: 'You investigate infrastructure issues.');
  const appdev = AgentRole(
      roleId: 'appdev', name: 'AppDev', title: 'Application Engineer',
      instruction: 'You investigate application defects.');
  const writer = AgentRole(
      roleId: 'writer', name: 'Writer', title: 'Comms Writer',
      instruction: 'You draft customer communications.');
  const editor = AgentRole(
      roleId: 'editor', name: 'Editor', title: 'Comms Editor',
      instruction: 'You critique customer communications.');

  var drafts = 0;
  final model = FakeVasterModel(handler: (request) {
    final text = request.messages.last.text;
    if (text.contains('Choose exactly one')) {
      // Router picks the app path; RefineLoop revises once then accepts.
      if (text.contains('own the investigation')) {
        return ModelResponse(
            message: ChatMessage.model(jsonEncode({'choice': 'application'})));
      }
      return ModelResponse(
          message: ChatMessage.model(
              jsonEncode({'choice': drafts >= 2 ? 'accept' : 'revise'})));
    }
    String reply;
    if (text.contains('logs angle')) {
      reply = 'Logs show a null deref in checkout after the 14:02 deploy.';
    } else if (text.contains('metrics angle')) {
      reply = 'Error rate spiked to 4% at 14:03, isolated to checkout.';
    } else if (text.contains('Merge the findings')) {
      reply = 'Root cause: 14:02 deploy introduced a checkout null deref.';
    } else if (text.contains('Draft the customer notice')) {
      drafts++;
      reply = 'Customer notice draft v$drafts.';
    } else if (text.contains('Critique this notice')) {
      reply = 'Tone is fine; add the resolution ETA.';
    } else if (text.contains('incident report')) {
      reply = jsonEncode({
        'severity': 'sev2',
        'summary': 'Checkout null deref from the 14:02 deploy.',
      });
    } else {
      reply = 'ack';
    }
    return ModelResponse(message: ChatMessage.model(reply));
  });

  final pipeline = Pipeline(
    name: 'incident_desk',
    children: [
      AgentTeam(
        roles: const [triager, sre, appdev, writer, editor],
        children: const [
          Knowledge(
            label: 'incident runbook',
            text: 'Sev1 = total outage. Sev2 = degraded core flow. Always '
                'identify the triggering change before communicating.',
            pinned: true,
            child: ContextBudget(
              maxTokens: 16000,
              child: Sequence([
                // 1. Model-steered triage to the right responder.
                Router(
                  prompt: 'A customer reports checkout failures since 14:00. '
                      'Which responder should own the investigation?',
                  routes: [
                    RouteCase(
                        label: 'infrastructure',
                        description: 'outages, capacity, networking',
                        agent: sre,
                        prompt: 'Investigate the infrastructure angle.',
                        output: Binding('triage_note')),
                    RouteCase(
                        label: 'application',
                        description: 'defects in application code',
                        agent: appdev,
                        prompt: 'Own the incident: coordinate the '
                            'investigation of the checkout failures.',
                        output: Binding('triage_note')),
                  ],
                  defaultRoute: 'infrastructure',
                ),

                // 2. Parallel investigation + synthesis (map-reduce).
                FanOut(
                  tasks: [
                    ParallelTaskEntry(
                        agentId: 'sre',
                        prompt: 'Investigate the metrics angle of the '
                            'checkout failures.',
                        output: 'metrics_findings'),
                    ParallelTaskEntry(
                        agentId: 'appdev',
                        prompt: 'Investigate the logs angle of the '
                            'checkout failures.',
                        output: 'logs_findings'),
                  ],
                  synthesize: Task(
                      agent: appdev,
                      prompt: 'Merge the findings into a root-cause '
                          'statement.\nMetrics: \${metrics_findings}\n'
                          'Logs: \${logs_findings}',
                      output: Binding('root_cause')),
                ),

                // 3. Worker/critic refinement of the customer notice.
                RefineLoop(
                  worker: Task(
                      agent: writer,
                      prompt: 'Draft the customer notice for this incident.\n'
                          'Root cause: \${root_cause}\n'
                          'Critique so far: \${critique}',
                      output: Binding('notice')),
                  critic: Task(
                      agent: editor,
                      prompt: 'Critique this notice: \${notice}',
                      output: Binding('critique')),
                  maxRounds: 4,
                ),

                // 4. Schema-typed incident report artifact.
                Produce(
                  agent: appdev,
                  prompt: 'Produce the final incident report as JSON.\n'
                      'Root cause: \${root_cause}\nNotice: \${notice}',
                  schema: {
                    'type': 'object',
                    'properties': {
                      'severity': {'type': 'string'},
                      'summary': {'type': 'string'},
                    },
                    'required': ['severity', 'summary'],
                  },
                  output: Binding('report'),
                  artifact: '/workspace/incident_report.json',
                  extract: {'severity': Binding('report_severity')},
                ),
                Output(from: Binding('report_severity')),
              ]),
            ),
          ),
        ],
      ),
    ],
  );

  final program = const BasicWorkflowCompiler().compile(pipeline);
  final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/workspace'));
  vm.eventBus.on<DecisionMadeEvent>().listen(
      (event) => stdout.writeln('[decision] ${event.chosenLabel}'));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  await Future<void>.delayed(Duration.zero);

  final report = await vm.fileSystemManager
      .resolveFileSystem('/workspace/incident_report.json')
      .readText('/workspace/incident_report.json');
  stdout.writeln('\nstatus   : ${state.status.name}');
  stdout.writeln('severity : ${state.registers['__output__']}');
  stdout.writeln('drafts   : $drafts (revised once, then accepted)');
  stdout.writeln('artifact : $report');
  await vm.shutdown();
}
