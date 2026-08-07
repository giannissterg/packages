part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Grounding kit — getting REAL content in front of the model.
//
// Every external-codebase pipeline starts the same way: read the target's
// actual files into bindings, then embed them in prompts as labeled
// sections. These nodes name that vocabulary; `Template.sections` is the
// companion for the prompt side.
// ══════════════════════════════════════════════════════════════════════════════

/// Reads a batch of files into bindings — the grounding block every
/// external-codebase pipeline opens with, as one node.
///
/// ```dart
/// Ground({plan: '/project/planning/plan.md', pubspec: '/project/pubspec.yaml'})
/// ```
class Ground extends ComposableNode {
  /// Binding ← literal path (keyed by binding, mirroring [Inputs]).
  final Map<Binding, String> files;

  /// The subtree these reads ground; omit to only read.
  final VasterNode? child;

  const Ground(this.files, {this.child});

  @override
  VasterNode build(BuildContext context) =>
      Sequence([for (final entry in files.entries) ReadFile.at(entry.value, output: entry.key), ?child]);
}

/// Reads a file and asks the model for a focused digest of it — grounding
/// for content too large (or too noisy) to embed whole.
///
/// Expands to `ReadFile` → `Task('Digest the following …')`. The digest
/// binds to [output]; the raw content stays in a scoped internal binding.
class Digest extends ComposableNode {
  final String of;
  final Binding output;
  final AgentRole? agent;
  final String? agentId;

  /// What the digest should surface (else a faithful general summary).
  final String? focus;

  const Digest({required this.of, required this.output, this.agent, this.agentId, this.focus})
    : assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final raw = context.scopedBinding('digest_raw');
    return Sequence([
      ReadFile.at(of, output: raw),
      Task(
        agent: agent,
        agentId: agentId,
        output: output,
        prompt: Template([
          'Digest the following content faithfully and concisely'
              '${focus == null ? '' : ' — focus on: $focus'}. '
              'Preserve concrete identifiers, paths, and numbers.\n\n'
              '--- $of ---\n',
          raw,
        ]),
      ),
    ]);
  }
}
