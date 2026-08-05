/// Shared war-room fixture: the full-surface stress pipeline and its
/// deterministic scripted model, reused by the stress suite and the
/// durability (DE-P5) suite.
library;

import 'dart:convert';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_ast/primitives.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

FakeVasterModel buildModel() {
  var toolCallIssued = false;
  return FakeVasterModel(
    handler: (request) async {
      final last = request.messages.isNotEmpty ? request.messages.last : null;
      final text = last?.text ?? '';

      // Tool loop: first sight of the registry prompt answers with a
      // tool_use; the transcript continuation (tool role present) answers
      // with the final text.
      if (text.contains('consult the registry') && !toolCallIssued) {
        toolCallIssued = true;
        return ModelResponse(
          message: const ChatMessage(role: Role.model, parts: [
            FunctionCallPart(
              callId: 'call_reg_1',
              name: 'lookup_registry',
              arguments: {'key': 'launch_window'},
            ),
          ]),
          finishReason: FinishReason.toolCalls,
        );
      }
      if (request.messages.any((m) => m.role == Role.tool)) {
        return ModelResponse(
          message: ChatMessage.model('registry cleared: window OPEN'),
          finishReason: FinishReason.stop,
        );
      }

      // Decide: the runtime asks for a JSON choice.
      if (text.contains('Choose exactly one')) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode({
            'choice': 'ship',
            'rationale': 'quality bar met',
          })),
          finishReason: FinishReason.stop,
        );
      }

      // Extraction source: structured status report.
      if (text.contains('produce the status report')) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode({
            'verdict': 'GO',
            'confidence': 0.97,
          })),
          finishReason: FinishReason.stop,
        );
      }

      return ModelResponse(
        message: ChatMessage.model('ack: ${text.length} chars processed'),
        finishReason: FinishReason.stop,
      );
    },
  );
}

// ── The complex plan ───────────────────────────────────────────────────
const architect = AgentRole(
  roleId: 'architect',
  name: 'Architect',
  title: 'Systems Architect',
  instruction: 'Design the launch. Be terse.',
);
const builder = AgentRole(
  roleId: 'builder',
  name: 'Builder',
  title: 'Build Engineer',
  instruction: 'Build what the architect designs.',
);
const reviewer = AgentRole(
  roleId: 'reviewer',
  name: 'Reviewer',
  title: 'Release Reviewer',
  instruction: 'Judge readiness honestly.',
);

Pipeline warRoom() => const Pipeline(
      name: 'launch_war_room',
      roles: [architect, builder, reviewer],
      mounts: [
        StorageMount(mountPrefix: '/workspace', type: StorageMountType.memory),
      ],
      inputs: {
        Binding('project'): 'orion',
        Binding('quality_bar'): 'high',
      },
      result: Binding('final_verdict'),
      children: [
        // Program-declared quota for the whole run.
        BudgetScope(
          maxTokens: 200000,
          maxCost: 5.0,
          child: Knowledge(
            label: 'launch brief',
            text: Template.text(
                'Project orion ships when quality bar is met.'),
            pinned: true,
            child: Sequence([
              // ① Direct prompt through the tool loop.
              Prompt(
                Template.text(
                    'Before anything, consult the registry for the launch window.'),
                output: Binding('registry_check'),
              ),

              // ② Subroutine defined, then called with arguments.
              DefineSubroutine(name: 'record_note', children: [
                WriteFile(
                  path: Template.text('/workspace/notes/\${note_name}.txt'),
                  content: Template.text('note: \${note_body}'),
                ),
              ]),
              CallSubroutine(name: 'record_note', arguments: {
                'note_name': 'kickoff',
                'note_body': 'war room open for project orion',
              }),

              // ③ Repeat loop writing numbered artifacts.
              Repeat(times: 2, children: [
                Prompt(Template.text('brainstorm one launch risk'),
                    output: Binding('risk')),
                WriteFile(
                  path: Template.text('/workspace/risks/risk.txt'),
                  content: Template.text('\${risk}'),
                ),
              ]),

              // ④ Agent work: single task with schema + parallel fan-out.
              Task(
                agent: architect,
                prompt: Template.text('Design the \${project} launch plan.'),
                output: Binding('design'),
                outputSchema: {
                  'type': 'object',
                  'properties': {
                    'plan': {'type': 'string'},
                  },
                },
              ),
              ParallelTasks(entries: [
                ParallelTaskEntry(
                  agentId: 'builder',
                  prompt: 'Build the launch runbook.',
                  output: 'runbook',
                ),
                ParallelTaskEntry(
                  agentId: 'reviewer',
                  prompt: 'Pre-review the design for gaps.',
                  output: 'prereview',
                ),
              ]),

              // ⑤ Actor messaging between agents.
              SendMessage(
                fromId: 'architect',
                toId: 'builder',
                payload: {'directive': 'follow the design for \${project}'},
              ),
              ReceiveMessage(agentId: 'builder', output: Binding('inbox')),

              // ⑥ Sandbox execution.
              Sandbox(
                env: CodeEnvironment(
                  envId: 'calc',
                  language: SandboxLanguage.dart,
                  timeoutMs: 5000,
                ),
                child:
                    Execute(code: Template.text('6 * 7'), output: Binding('calc_out')),
              ),

              // ⑦ Transaction + TryCatch: recoverable VFS failure.
              Transaction(children: [
                WriteFile(
                  path: Template.text('/workspace/txn/committed.txt'),
                  content: Template.text('txn ok'),
                ),
              ]),
              TryCatch(
                tryChildren: [
                  ReadFile(path: Template.text('/workspace/missing/nope.txt')),
                ],
                catchChildren: [
                  WriteFile(
                    path: Template.text('/workspace/txn/recovered.txt'),
                    content: Template.text('recovered from \${vfs_err}'),
                  ),
                ],
                error: 'vfs_err',
              ),

              // ⑧ Structured status + JSON extraction.
              Prompt(
                Template.text('Now produce the status report as JSON.'),
                output: Binding('status_json'),
              ),
              Extract(
                from: Binding('status_json'),
                field: 'verdict',
                output: Binding('verdict'),
              ),

              // ⑨ Model-steered decision gates the human gate.
              Decide(
                prompt: Template.text('Is \${project} ready to ship?'),
                output: Binding('ship_decision'),
                paths: [
                  DecisionPath(
                    label: 'ship',
                    description: 'quality bar met, proceed to approval',
                    children: [
                      ApprovalGate(
                        requestId: 'launch_gate',
                        prompt: Template.text(
                            'Human sign-off: ship \${project}? Registry said \${registry_check}'),
                        onApprove: [
                          WriteFile(
                            path: Template.text('/workspace/LAUNCH.txt'),
                            content: Template.text(
                                'LAUNCHED \${project}: \${verdict} (calc \${calc_out})'),
                          ),
                          Inputs({Binding('final_verdict'): 'shipped'}),
                        ],
                        onReject: [
                          Inputs({Binding('final_verdict'): 'aborted'}),
                        ],
                      ),
                    ],
                  ),
                  DecisionPath(
                    label: 'iterate',
                    description: 'not ready, loop back',
                    children: [
                      Inputs({Binding('final_verdict'): 'iterating'}),
                    ],
                  ),
                ],
              ),
            ]),
          ),
        ),
      ],
    );


/// The registry FunctionTool the war-room model calls through the tool loop.
ExecutableTool buildRegistryTool() => FunctionTool.define(
      name: 'lookup_registry',
      description: 'Looks up a launch-registry key.',
      parametersSchema: const {
        'type': 'object',
        'properties': {
          'key': {'type': 'string'},
        },
      },
      handler: (args) async => {'value': 'OPEN', 'key': args['key']},
    );
