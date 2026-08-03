part of '../vaster_ast.dart';

// ══════════════════════════════════════════════════════════════════════════════
// SDD workflow kit — spec-driven development as a declarative phase TREE.
//
// The way people drive LLM development today: a goal becomes spec.md, the
// spec becomes plan.md, the plan fans out into workstreams, and reviews gate
// each hand-off. Here those markdown artifacts live in the VFS and ARE the
// coordination medium between agents: every phase reads its predecessor's
// artifact (ReadFile + `${...}` interpolation) and writes its own (WriteFile).
//
// Phases are scope nodes that NEST — the tree structure is the workflow's
// dependency structure, not a flat step list:
//
//   Specify(goal: ..., agent: architect, children: [
//     Plan(agent: lead, children: [
//       Review(gate: true, onApprove: [
//         Implement(workstreams: [...], children: [ ...ship... ]),
//       ], onRevise: [ ... ]),
//     ]),
//   ])
//
// A child runs inside its parent phase's scope: the parent's artifact exists
// and its binding (`spec`, `plan`, ...) is in force. Conventions flow
// Theme-style via Provider<SddConventions>; node-level fields override.
// Bindings produced: Specify → `spec`; Plan → `plan` (reads `spec_doc`);
// Implement → each Workstream.output (reads `plan_doc`); Review → `review`
// and its verdict in `review_verdict`.
// ══════════════════════════════════════════════════════════════════════════════

/// Artifact-path conventions for the SDD kit, injected via
/// `Provider<SddConventions>`.
class SddConventions {
  final String root;
  final String specFile;
  final String planFile;
  final String reviewFile;

  const SddConventions({
    this.root = '/workspace',
    this.specFile = 'spec.md',
    this.planFile = 'plan.md',
    this.reviewFile = 'review.md',
  });

  String get specPath => '$root/$specFile';
  String get planPath => '$root/$planFile';
  String get reviewPath => '$root/$reviewFile';
}

/// Phase 1 — turn a [goal] into a written specification, then run [children]
/// inside the specified scope (the spec artifact exists and `spec` is bound).
///
/// Expands to: `Task(output: 'spec')` → `WriteFile(specPath, '${spec}')` →
/// children. The goal may interpolate pipeline [Inputs].
class Specify extends ComposableNode {
  final String goal;
  final AgentRole? agent;
  final String? agentId;

  /// Artifact path override (default: the conventions' spec path).
  final String? artifact;

  final List<VasterNode> children;

  const Specify({
    required this.goal,
    this.agent,
    this.agentId,
    this.artifact,
    this.children = const [],
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    return Sequence([
      Task(
        agent: agent,
        agentId: agentId,
        output: 'spec',
        prompt: 'Write a complete, reviewable specification in Markdown for '
            'the following goal. Cover scope, requirements, non-goals, and '
            'acceptance criteria.\n\nGoal: $goal',
      ),
      WriteFile(path: artifact ?? conventions.specPath, content: r'${spec}'),
      ...children,
    ]);
  }
}

/// Phase 2 — derive an implementation plan from the specification artifact,
/// then run [children] inside the planned scope.
///
/// Expands to: `ReadFile(specPath, output: 'spec_doc')` →
/// `Task(output: 'plan')` → `WriteFile(planPath, '${plan}')` → children.
class Plan extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;

  /// Spec artifact to read (default: the conventions' spec path).
  final String? from;

  /// Plan artifact to write (default: the conventions' plan path).
  final String? artifact;

  final List<VasterNode> children;

  const Plan({
    this.agent,
    this.agentId,
    this.from,
    this.artifact,
    this.children = const [],
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    return Sequence([
      ReadFile(path: from ?? conventions.specPath, output: 'spec_doc'),
      Task(
        agent: agent,
        agentId: agentId,
        output: 'plan',
        prompt: 'Produce a concrete implementation plan in Markdown for the '
            'specification below: ordered milestones, workstreams with clear '
            'boundaries, file-level changes, and verification steps.\n\n'
            'Specification:\n\${spec_doc}',
      ),
      WriteFile(path: artifact ?? conventions.planPath, content: r'${plan}'),
      ...children,
    ]);
  }
}

/// One workstream of an [Implement] phase.
class Workstream {
  final AgentRole? agent;
  final String? agentId;

  /// What this workstream owns (embedded in the agent's prompt).
  final String focus;

  /// Binding name for the workstream's result.
  final String output;

  /// Optional artifact path the result is written to.
  final String? artifact;

  const Workstream({
    this.agent,
    this.agentId,
    required this.focus,
    required this.output,
    this.artifact,
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');
}

/// Phase 3 — execute the plan as concurrent [workstreams], each grounded in
/// the plan artifact, then run [children] with every workstream output bound
/// (a child [Task] typically integrates them via interpolation).
///
/// Expands to: `ReadFile(planPath, output: 'plan_doc')` → `FanOut` (one entry
/// per workstream, prompts embedding the plan) → per-workstream artifact
/// writes → children.
class Implement extends ComposableNode {
  final List<Workstream> workstreams;

  /// Plan artifact to read (default: the conventions' plan path).
  final String? from;

  final List<VasterNode> children;

  const Implement({
    required this.workstreams,
    this.from,
    this.children = const [],
  });

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    return Sequence([
      ReadFile(path: from ?? conventions.planPath, output: 'plan_doc'),
      FanOut(
        tasks: [
          for (final ws in workstreams)
            ParallelTaskEntry(
              agentId: ws.agent?.roleId ?? ws.agentId ?? 'default',
              output: ws.output,
              prompt: 'Execute your workstream of the implementation plan '
                  'below. Own it end to end and produce the deliverable in '
                  'Markdown.\n\nYour workstream: ${ws.focus}\n\n'
                  'Plan:\n\${plan_doc}',
            ),
        ],
      ),
      for (final ws in workstreams)
        if (ws.artifact != null)
          WriteFile(path: ws.artifact!, content: '\${${ws.output}}'),
      ...children,
    ]);
  }
}

/// Review phase — a critic reads an artifact, writes a review artifact, and
/// the verdict steers the tree: the approved continuation nests under
/// [onApprove], the rework path under [onRevise]. Model-decided by default;
/// a human [ApprovalGate] when [gate] is true.
///
/// Expands to: `ReadFile(of)` → `Task(output: 'review')` →
/// `WriteFile(reviewPath, '${review}')` → `Decide(approve/revise)` (or an
/// ApprovalGate over the same review when gated). The decision label binds
/// to `review_verdict`.
class Review extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;

  /// Artifact path to review (default: the conventions' plan path).
  final String? of;

  /// Review artifact to write (default: the conventions' review path).
  final String? artifact;

  /// When true, a human approves/rejects instead of the model deciding.
  final bool gate;

  /// HITL request id used when [gate] is true.
  final String requestId;

  final List<VasterNode> onApprove;
  final List<VasterNode> onRevise;

  const Review({
    this.agent,
    this.agentId,
    this.of,
    this.artifact,
    this.gate = false,
    this.requestId = 'sdd_review',
    this.onApprove = const [],
    this.onRevise = const [],
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    final target = of ?? conventions.planPath;
    final reviewSteps = <VasterNode>[
      ReadFile(path: target, output: 'review_target'),
      Task(
        agent: agent,
        agentId: agentId,
        output: 'review',
        prompt: 'Review the artifact below rigorously: correctness, '
            'completeness, risks, and whether it meets its stated goal. '
            'End with a clear APPROVE or REVISE recommendation.\n\n'
            'Artifact ($target):\n\${review_target}',
      ),
      WriteFile(path: artifact ?? conventions.reviewPath, content: r'${review}'),
    ];
    if (gate) {
      return Sequence([
        ...reviewSteps,
        ApprovalGate(
          requestId: requestId,
          prompt: 'A review of $target is ready:\n\n\${review}\n\nApprove?',
          onApprove: onApprove,
          onReject: onRevise,
        ),
      ]);
    }
    return Sequence([
      ...reviewSteps,
      Decide(
        prompt: 'Based on this review, should the artifact be approved or '
            'sent back for revision?\n\nReview:\n\${review}',
        output: 'review_verdict',
        defaultPath: 'approve',
        paths: [
          DecisionPath(
            label: 'approve',
            description: 'the review recommends approval',
            children: onApprove,
          ),
          DecisionPath(
            label: 'revise',
            description: 'the review found issues that must be addressed',
            children: onRevise,
          ),
        ],
      ),
    ]);
  }
}
