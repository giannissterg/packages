part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// SDD workflow kit — spec-driven development as a declarative phase TREE.
//
// The way people drive LLM development today: a goal becomes spec.md, the
// spec becomes plan.md, the plan fans out into workstreams, and reviews gate
// each hand-off. Here those markdown artifacts live in the VFS and ARE the
// coordination medium between agents: every phase reads its predecessor's
// artifact (ReadFile + `${...}` interpolation) and writes its own (WriteFile).
//
// Nest vs sequence — the tree's design rule: a node NESTS children only
// when it changes what they mean (who executes them, their environment,
// their failure semantics, or whether they run at all); peer steps that
// merely run one after another are SIBLINGS in sequence. Data dependency
// alone never forces nesting — bindings and `${...}` interpolation cross
// sibling boundaries. So the phases read as the SDD checklist itself, and
// only conditionality nests:
//
//   Pipeline(children: [
//     Specify(goal: ..., agent: architect),
//     Plan(agent: lead),
//     Review(agent: reviewer, onApprove: [
//       Implement(workstreams: [...]),       // exists only when approved
//     ], onRevise: [ ... ]),
//   ])
//
// Conventions flow
// Theme-style via Provider<SddConventions>; node-level fields override.
// Bindings produced: Specify → `spec`; Plan → `plan` (reads `spec_doc`);
// Implement → each Workstream.output (reads `plan_doc`); Review → `review`
// and its verdict in `review_verdict`.
// ══════════════════════════════════════════════════════════════════════════════

/// Shared suffix for every artifact-producing phase prompt: real models
/// open with conversational scaffolding ("I'll review this plan…") that
/// then leaks into the written artifact. Documents must be documents.
const String _documentOnly =
    '\n\nOutput only the document itself, starting with its first Markdown '
    'heading — no preamble, no commentary, no closing remarks.';

/// Artifact-path conventions for the SDD kit, injected via
/// `Provider<SddConventions>`.
class SddConventions {
  final String root;
  final String specFile;
  final String planFile;
  final String reviewFile;
  final String verifyFile;

  const SddConventions({
    this.root = '/workspace',
    this.specFile = 'spec.md',
    this.planFile = 'plan.md',
    this.reviewFile = 'review.md',
    this.verifyFile = 'verification.md',
  });

  String get specPath => '$root/$specFile';

  /// Namespaces an artifact path's filename under the enclosing
  /// [BindingScope]: `/workspace/spec.md` → `/workspace/checkout_spec.md`.
  static String scopedPath(BuildContext context, String path) {
    final ns = context.tryRead<BindingScopeData>()?.namespace ?? '';
    if (ns.isEmpty) return path;
    final slash = path.lastIndexOf('/');
    return '${path.substring(0, slash + 1)}${ns}_${path.substring(slash + 1)}';
  }

  String get planPath => '$root/$planFile';
  String get reviewPath => '$root/$reviewFile';
  String get verifyPath => '$root/$verifyFile';
}

/// Phase 0 — gather requirements from a human before specifying: the model
/// asks one question per round and decides when it knows enough. The
/// accumulated Q&A notes bind to [output] (default `clarifications`) for
/// [Specify] to interpolate (`Goal: ... ${clarifications}`).
///
/// Expands to a [DecideLoop] whose body is: generate the next question →
/// [AskHuman] → fold the answer into the running notes. [maxQuestions]
/// bounds the loop (else `DecisionPolicy.maxIterations`, else 8).
class Clarify extends ComposableNode {
  final String topic;
  final AgentRole? agent;
  final String? agentId;
  final int? maxQuestions;

  /// Defaults to `clarifications`, namespaced by the enclosing
  /// [BindingScope].
  final Binding? output;

  const Clarify({
    required this.topic,
    this.agent,
    this.agentId,
    this.maxQuestions,
    this.output,
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final output = this.output ?? context.scopedBinding('clarifications');
    final question = context.scopedBinding('clarify_question');
    final answer = context.scopedBinding('clarify_answer');
    return Sequence([
      InputsHeader(values: {output.name: '(nothing gathered yet)'}),
      DecideLoop(
        prompt: Template([
          'You are gathering requirements about: $topic\n\n'
              'Clarifications so far:\n',
          output,
          '\n\nDo you have enough information to write a specification, or '
              'should you ask another question?',
        ]),
        continueLabel: 'ask',
        continueDescription: 'important information is still missing',
        maxIterations: maxQuestions,
        body: [
          Task(
            agent: agent,
            agentId: agentId,
            output: question,
            prompt: Template([
              'You are gathering requirements about: $topic\n'
                  'Clarifications so far:\n',
              output,
              '\n\nAsk the single most important unanswered question. '
                  'Reply with only the question.',
            ]),
          ),
          AskHuman(
            requestId: 'clarify',
            prompt: Template([question]),
            output: answer,
          ),
          Task(
            agent: agent,
            agentId: agentId,
            output: output,
            prompt: Template([
              'Update the clarification notes with the new exchange.\n\n'
                  'Notes so far:\n',
              output,
              '\n\nQ: ',
              question,
              '\nA: ',
              answer,
              '\n\nReply with the complete updated notes in Markdown.'
                  '$_documentOnly',
            ]),
          ),
        ],
        exits: const [
          DecisionPath(
            label: 'ready',
            description: 'enough information has been gathered to specify',
          ),
        ],
        defaultPath: 'ready',
      ),
    ]);
  }
}

/// Verification phase — run [run] in a sandbox, write the output as the
/// verification artifact, and let the model judge it: [onPass] nests the
/// verified continuation, [onFail] the remediation path (typically a revise
/// loop back into implementation). An unresolvable judgment defaults to
/// FAIL — verification is the one gate that must not pass on ambiguity.
///
/// Expands to: `Execute(run, output: const Binding('verification'))` →
/// `WriteFile(verifyPath, '${verification}')` → `Decide(pass/fail,
/// output: const Binding('verification_verdict'), defaultPath: 'fail')`.
class Verify extends ComposableNode {
  /// Code or command to execute in the sandbox.
  final Template run;

  /// Sandbox environment id; omit to inherit the enclosing [Sandbox] scope.
  final String? envId;

  final List<VasterNode> onPass;
  final List<VasterNode> onFail;

  const Verify({
    required this.run,
    this.envId,
    this.onPass = const [],
    this.onFail = const [],
  });

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    final verification = context.scopedBinding('verification');
    return Sequence([
      Execute(envId: envId, code: run, output: verification),
      WriteFile(
          path: Template.text(
              SddConventions.scopedPath(context, conventions.verifyPath)),
          content: Template([verification])),
      Decide(
        prompt: Template([
          'Below is the output of the verification run. Did verification '
              'pass — no failures, errors, or unmet expectations?\n\nOutput:\n',
          verification,
        ]),
        output: context.scopedBinding('verification_verdict'),
        defaultPath: 'fail',
        paths: [
          DecisionPath(
            label: 'pass',
            description: 'the output shows verification succeeded',
            children: onPass,
          ),
          DecisionPath(
            label: 'fail',
            description: 'the output shows failures or is inconclusive',
            children: onFail,
          ),
        ],
      ),
    ]);
  }
}

/// Phase 1 — turn a [goal] into a written specification: after this phase,
/// the spec artifact exists and `spec` is bound for every later sibling.
///
/// Expands to: `Task(output: const Binding('spec'))` → `WriteFile(specPath, '${spec}')`.
/// The goal may interpolate pipeline [Inputs].
class Specify extends ComposableNode {
  final String goal;
  final AgentRole? agent;
  final String? agentId;

  /// Defaults to `spec`, namespaced by the enclosing [BindingScope].
  final Binding? output;

  /// Artifact path override (default: the conventions' spec path).
  final String? artifact;

  const Specify({
    required this.goal,
    this.agent,
    this.agentId,
    this.artifact,
    this.output,
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    final spec = output ?? context.scopedBinding('spec');
    return Sequence([
      Task(
        agent: agent,
        agentId: agentId,
        output: spec,
        prompt: Template.text(
            'Write a complete, reviewable specification in Markdown for '
            'the following goal. Cover scope, requirements, non-goals, and '
            'acceptance criteria.\n\nGoal: $goal$_documentOnly'),
      ),
      WriteFile(
          path: Template.text(SddConventions.scopedPath(
              context, artifact ?? conventions.specPath)),
          content: Template([spec])),
    ]);
  }
}

/// Phase 2 — derive an implementation plan from the specification artifact.
///
/// Expands to: `ReadFile(specPath, output: const Binding('spec_doc'))` →
/// `Task(output: const Binding('plan'))` → `WriteFile(planPath, '${plan}')`.
class Plan extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;

  /// Defaults to `plan`, namespaced by the enclosing [BindingScope].
  final Binding? output;

  /// Spec artifact to read (default: the conventions' spec path).
  final String? from;

  /// Plan artifact to write (default: the conventions' plan path).
  final String? artifact;

  /// Binding name of a critique to address (e.g. `'review'` inside a
  /// `Review(revise: Plan(...))` loop). When set, the bound review is
  /// embedded and the planner is instructed to fix every blocking issue.
  final Binding? addressing;

  const Plan({
    this.agent,
    this.agentId,
    this.from,
    this.artifact,
    this.addressing,
    this.output,
  }) : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    final specDoc = context.scopedBinding('spec_doc');
    final plan = output ?? context.scopedBinding('plan');
    return Sequence([
      ReadFile(
          path: Template.text(SddConventions.scopedPath(
              context, from ?? conventions.specPath)),
          output: specDoc),
      Task(
        agent: agent,
        agentId: agentId,
        output: plan,
        prompt: Template([
          'Produce a concrete implementation plan in Markdown for the '
              'specification below: ordered milestones, workstreams with '
              'clear boundaries, file-level changes, and verification '
              'steps.\n\nSpecification:\n',
          specDoc,
          if (addressing != null) ...[
            '\n\nA review of the previous version follows — address every '
                'blocking issue it names:\n',
            addressing!,
          ],
          _documentOnly,
        ]),
      ),
      WriteFile(
          path: Template.text(SddConventions.scopedPath(
              context, artifact ?? conventions.planPath)),
          content: Template([plan])),
    ]);
  }
}

/// One workstream of an [Implement] phase.
class Workstream {
  final AgentRole? agent;
  final String? agentId;

  /// What this workstream owns (embedded in the agent's prompt).
  final String focus;

  /// Binding for the workstream's result.
  final Binding output;

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
/// the plan artifact. [integrate] is the phase's fan-in slot (typically a
/// [Task] interpolating the workstream outputs) — it belongs to the phase
/// because a fan-out's join is part of its meaning.
///
/// Expands to: `ReadFile(planPath, output: const Binding('plan_doc'))` → `FanOut` (one entry
/// per workstream, prompts embedding the plan) → per-workstream artifact
/// writes → integrate.
class Implement extends ComposableNode {
  final List<Workstream> workstreams;

  /// Plan artifact to read (default: the conventions' plan path).
  final String? from;

  /// Fan-in step run with every workstream output bound.
  final VasterNode? integrate;

  const Implement({required this.workstreams, this.from, this.integrate});

  @override
  VasterNode build(BuildContext context) {
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    final planDoc = context.scopedBinding('plan_doc');
    return Sequence([
      ReadFile(
          path: Template.text(SddConventions.scopedPath(
              context, from ?? conventions.planPath)),
          output: planDoc),
      FanOut(
        tasks: [
          for (final ws in workstreams)
            // ParallelTaskEntry is a vaster_domain spec type — string tier.
            ParallelTaskEntry(
              agentId: ws.agent?.roleId ?? ws.agentId ?? 'default',
              output: ws.output.name,
              prompt: 'Execute your workstream of the implementation plan '
                  'below. Own it end to end and produce the deliverable in '
                  'Markdown.\n\nYour workstream: ${ws.focus}\n\n'
                  'Plan:\n\${${planDoc.name}}$_documentOnly',
            ),
        ],
      ),
      for (final ws in workstreams)
        if (ws.artifact != null)
          WriteFile(
              path: Template.text(ws.artifact!),
              content: Template([ws.output])),
      ?integrate,
    ]);
  }
}

/// Review phase — a critic reads an artifact, writes a review artifact, and
/// the verdict steers the tree. Model-decided by default; a human
/// [ApprovalGate] when [gate] is true.
///
/// The verdict standard is **blocking issues only**: an artifact with minor
/// improvements still gets approved (with notes) — revision is reserved for
/// issues that genuinely block the goal. Real reviewers otherwise reject
/// everything and the pipeline never ships.
///
/// Three continuation shapes:
/// - `onApprove` nests the approved continuation.
/// - `onRevise` (with no [revise] slot) is a terminal rework path.
/// - **[revise] closes the loop**: a node that regenerates the artifact
///   (typically the same `Plan(...)` that produced it). On a revise verdict
///   the artifact is regenerated — with `${review}` bound, so the producer
///   can interpolate the critique — then re-reviewed, up to [maxRounds]
///   (else `DecisionPolicy.maxIterations`). Exhaustion approves and
///   proceeds: an endless review cycle must not hang the pipeline.
///
/// The decision label binds to `review_verdict`.
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

  /// Regenerates the reviewed artifact on a revise verdict, closing the
  /// review loop. Mutually exclusive with [onRevise] and [gate].
  final VasterNode? revise;

  /// Review-round bound when [revise] is set.
  final int? maxRounds;

  /// Defaults to `review`, namespaced by the enclosing [BindingScope].
  final Binding? output;

  /// Defaults to `review_verdict`, namespaced by the enclosing
  /// [BindingScope].
  final Binding? verdict;

  const Review({
    this.agent,
    this.agentId,
    this.of,
    this.artifact,
    this.gate = false,
    this.requestId = 'sdd_review',
    this.onApprove = const [],
    this.onRevise = const [],
    this.revise,
    this.maxRounds,
    this.output,
    this.verdict,
  })  : assert(agent == null || agentId == null,
            'Provide at most one of agent/agentId'),
        assert(revise == null || !gate,
            'The revise loop is model-decided; combine gate with onRevise');

  @override
  VasterNode build(BuildContext context) {
    assert(revise == null || onRevise.isEmpty,
        'Provide either revise (loop) or onRevise (terminal), not both');
    final conventions = context.tryRead<SddConventions>() ?? const SddConventions();
    final target =
        SddConventions.scopedPath(context, of ?? conventions.planPath);
    final reviewTarget = context.scopedBinding('review_target');
    final review = output ?? context.scopedBinding('review');
    final reviewVerdict = verdict ?? context.scopedBinding('review_verdict');
    final reviewSteps = <VasterNode>[
      ReadFile(path: Template.text(target), output: reviewTarget),
      Task(
        agent: agent,
        agentId: agentId,
        output: review,
        prompt: Template([
          'Review the artifact below: correctness, completeness, '
              'risks, and whether it meets its stated goal. Hold it to a '
              'shipping standard, not a perfection standard — note minor '
              'improvements, but recommend revision only for issues that '
              'genuinely block the goal. End with a clear APPROVE or REVISE '
              'recommendation.\n\nArtifact ($target):\n',
          reviewTarget,
          _documentOnly,
        ]),
      ),
      WriteFile(
          path: Template.text(SddConventions.scopedPath(
              context, artifact ?? conventions.reviewPath)),
          content: Template([review])),
    ];
    // Calibration note (claude-cli recording, 2026-08-04): backends without
    // schema enforcement will happily re-review the artifact and override the
    // reviewer's verdict. The decider must apply the review, not redo it.
    final decidePrompt = Template([
      'Based on this review, should the artifact be approved or sent back '
          'for revision? Approve unless the review names blocking issues. '
          'Do not re-review the artifact yourself — judge only from the '
          'review text, deferring to its own recommendation when it states '
          'one.\n\nReview:\n',
      review,
    ]);
    const approveDescription =
        'no blocking issues — minor notes can ride along';
    const reviseDescription = 'blocking issues must be fixed first';

    if (gate) {
      return Sequence([
        ...reviewSteps,
        ApprovalGate(
          requestId: requestId,
          prompt: Template([
            'A review of $target is ready:\n\n',
            review,
            '\n\nApprove?',
          ]),
          onApprove: onApprove,
          onReject: onRevise,
        ),
      ]);
    }
    if (revise != null) {
      // Decide-first loop (empty body): judge the existing review; a revise
      // verdict regenerates the artifact and re-reviews on the continue
      // edge; exhaustion falls through to approve.
      return Sequence([
        ...reviewSteps,
        DecideLoop(
          prompt: decidePrompt,
          output: reviewVerdict,
          body: const [],
          continueLabel: 'revise',
          continueDescription: reviseDescription,
          onContinue: [revise!, ...reviewSteps],
          exits: [
            DecisionPath(
              label: 'approve',
              description: approveDescription,
              children: onApprove,
            ),
          ],
          defaultPath: 'approve',
          maxIterations: maxRounds,
        ),
      ]);
    }
    return Sequence([
      ...reviewSteps,
      Decide(
        prompt: decidePrompt,
        output: reviewVerdict,
        defaultPath: 'approve',
        paths: [
          DecisionPath(
            label: 'approve',
            description: approveDescription,
            children: onApprove,
          ),
          DecisionPath(
            label: 'revise',
            description: reviseDescription,
            children: onRevise,
          ),
        ],
      ),
    ]);
  }
}
