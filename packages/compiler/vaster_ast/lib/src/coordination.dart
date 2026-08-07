part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Coordination pattern library — multi-agent composition primitives.
//
// Every node here is a ComposableNode expanding to existing primitives; the
// compiler needs no knowledge of them. Each doc comment carries an
// "Expands to:" sketch, the Provider policies respected, and the value-flow
// features consumed (output bindings + ${name} interpolation).
//
// Recipes intentionally NOT shipped as nodes:
//  * Vote/Consensus — a [FanOut] whose `synthesize` Task tallies the parallel
//    opinions: FanOut(tasks: [one entry per voter, output: 'vote_i'],
//    synthesize: Task(prompt: 'Tally: ${vote_1} ... pick the majority')).
//  * Debate — successive [FanOut] rounds whose entry prompts interpolate the
//    opponents' previous-round outputs (deterministic names '<id>_r<N>'),
//    then a judge Task over the final round.
//  * Delegate/Ask — [Task] already is synchronous request-reply with a named
//    output; the actor inbox (SendMessage/ReceiveMessage) is for async flows.
//  * Checkpoint — [Transaction] already is the rollback boundary.
// ══════════════════════════════════════════════════════════════════════════════

/// Provisions a team of agents in one node, then runs [children].
///
/// Works mid-tree: place it under [SelectModel]/[ToolSet]/[BudgetScope] to
/// scope the whole team. Provisioning is deduplicated with `Pipeline.roles`
/// and nested [Agent] scopes.
///
/// Expands to: `Provider<List<AgentRole>>( Sequence([Agent(r1), ..., children]) )`
/// — each Agent emits CreateAgent + CreateSession once.
class AgentTeam extends ComposableNode {
  final List<AgentRole> roles;
  final List<VasterNode> children;

  const AgentTeam({required this.roles, this.children = const []});

  @override
  VasterNode build(BuildContext context) {
    return Provider<List<AgentRole>>(
      value: roles,
      children: [
        Sequence([for (final role in roles) Agent(role: role), ...children]),
      ],
    );
  }
}

/// Map-reduce over agents: dispatch [tasks] concurrently, then run
/// [synthesize] — typically a [Task] whose prompt interpolates the entries'
/// `output` names (`${a} ... ${b}`).
///
/// Expands to: `Sequence([ParallelTasks(tasks), synthesize?])`.
class FanOut extends ComposableNode {
  final List<ParallelTaskEntry> tasks;
  final VasterNode? synthesize;

  const FanOut({required this.tasks, this.synthesize});

  @override
  VasterNode build(BuildContext context) {
    return Sequence([ParallelTasks(entries: tasks), ?synthesize]);
  }
}

/// Iterative worker/critic refinement: [worker] produces, [critic] reviews
/// into [critiqueOutput], and the model decides whether to revise again or
/// accept. Built on [DecideLoop], so `Provider<DecisionPolicy>` governs
/// iteration bounds; exhaustion always terminates through the accept exit.
///
/// Conventions: [worker] should declare an `output:` and may interpolate
/// `${critiqueOutput}` (empty verbatim on round one — seed it via [Inputs]
/// for a clean first pass, or phrase the worker prompt accordingly);
/// [critic] must bind [critiqueOutput].
///
/// Expands to:
/// `DecideLoop(body: [worker, critic], exits: [accept -> onAccept],
///  defaultPath: acceptLabel)`.
class RefineLoop extends ComposableNode {
  final Task worker;
  final Task critic;
  final Binding critiqueOutput;
  final String acceptLabel;
  final String acceptDescription;
  final List<VasterNode> onAccept;
  final int? maxRounds;
  final Binding? output;

  const RefineLoop({
    required this.worker,
    required this.critic,
    this.critiqueOutput = const Binding('critique'),
    this.acceptLabel = 'accept',
    this.acceptDescription = 'the work meets the bar — stop iterating',
    this.onAccept = const [],
    this.maxRounds,
    this.output,
  });

  @override
  VasterNode build(BuildContext context) {
    return DecideLoop(
      prompt: Template([
        'Latest critique:\n',
        critiqueOutput,
        '\n\nGiven this critique, does the work meet the bar, or is another '
            'revision pass needed?',
      ]),
      continueLabel: 'revise',
      continueDescription: 'the critique lists issues that must be addressed',
      body: [worker, critic],
      exits: [DecisionPath(label: acceptLabel, description: acceptDescription, children: onAccept)],
      defaultPath: acceptLabel,
      maxIterations: maxRounds,
      output: output,
    );
  }
}

/// One route of a [Router]: the model selects it by [label], guided by
/// [description], and the route's task dispatches to its agent.
class RouteCase {
  final String label;
  final String description;
  final AgentRole? agent;
  final String? agentId;
  final Template prompt;
  final Binding? output;

  const RouteCase({
    required this.label,
    required this.description,
    this.agent,
    this.agentId,
    required this.prompt,
    this.output,
  }) : assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');
}

/// Model-steered dispatch: the model triages [prompt] and routes to exactly
/// one [RouteCase]'s agent. Sugar over [Decide] — every destination stays
/// statically known.
///
/// Expands to: `Decide(paths: [DecisionPath(label, description,
/// children: [Task(agent, prompt, output)])], defaultPath: defaultRoute)`.
class Router extends ComposableNode {
  final Template prompt;
  final List<RouteCase> routes;
  final String? defaultRoute;
  final Binding? output;

  const Router({required this.prompt, required this.routes, this.defaultRoute, this.output});

  @override
  VasterNode build(BuildContext context) {
    return Decide(
      prompt: prompt,
      defaultPath: defaultRoute,
      output: output,
      paths: [
        for (final route in routes)
          DecisionPath(
            label: route.label,
            description: route.description,
            children: [
              Task(agent: route.agent, agentId: route.agentId, prompt: route.prompt, output: route.output),
            ],
          ),
      ],
    );
  }
}

/// Produces a schema-typed deliverable in one node: the agent's response is
/// constrained by [schema], bound to [output], optionally persisted to
/// [artifact], and destructured field-by-field via [extract]
/// (`{'jsonField': 'bindingName'}`).
///
/// Expands to: `Task(outputSchema: schema, output:)` →
/// `Extract(field → binding)*` → `WriteFile(artifact, '${output}')?`.
///
/// ```dart
/// Produce(
///   agent: architect,
///   prompt: 'Design the storage layer.',
///   schema: {'type': 'object', 'properties': {'summary': ..., 'risks': ...}},
///   output: 'design',
///   artifact: '/workspace/design.json',
///   extract: {'summary': 'design_summary', 'risks': 'design_risks'},
/// )
/// ```
class Produce extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;
  final Template prompt;
  final Map<String, dynamic> schema;
  final Binding output;
  final String? artifact;

  /// JSON field name → binding the field destructures into.
  final Map<String, Binding> extract;

  const Produce({
    this.agent,
    this.agentId,
    required this.prompt,
    required this.schema,
    required this.output,
    this.artifact,
    this.extract = const {},
  }) : assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    return Sequence([
      Task(agent: agent, agentId: agentId, prompt: prompt, outputSchema: schema, output: output),
      for (final entry in extract.entries) Extract(from: output, field: entry.key, output: entry.value),
      if (artifact != null) WriteFile(path: Template.text(artifact!), content: Template([output])),
    ]);
  }
}

/// Retries [child] up to `attempts` times (node field, else
/// `Provider<RetryPolicy>` — the shared retry vocabulary from
/// `vaster_model` — else 3): the first successful attempt continues
/// past the node; each failure's error text binds to `retry_error` so a
/// later attempt's prompt may interpolate it. [onExhausted] runs when
/// every attempt failed.
///
/// **A first-class ISA construct**: compiles to the canonical retry LOOP
/// (counter init → guarded back-edge → handler around the child →
/// increment on catch) — constant code size regardless of [attempts],
/// and the loop guard is the compiler's canonical bounded shape, so
/// `vaster check`'s cost bound automatically multiplies the child's
/// worst case by the attempt ceiling: declared retries are PRICED.
/// Policy violations are uncatchable and are never retried.
class Resilient extends VasterNode {
  final VasterNode child;
  final int? attempts;
  final List<VasterNode> onExhausted;

  const Resilient({required this.child, this.attempts, this.onExhausted = const []});
}
