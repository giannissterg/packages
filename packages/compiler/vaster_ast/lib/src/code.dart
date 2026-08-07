part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Code kit — pipelines that write and revise source files.
//
// Extracted from the external-codebase dogfoods: [Author] writes a file
// from one agent turn under a content discipline; [Revise] is the
// read-current → regenerate-addressing-a-critique pair that closes review
// loops. [Produce] (coordination kit) remains the schema'd sibling.
// ══════════════════════════════════════════════════════════════════════════════

/// Content discipline appended to an [Author] prompt: models love preambles
/// and markdown fences; files must be files.
enum AuthorDiscipline {
  /// Markdown documents: "output only the document, starting with its
  /// first heading" (the SDD kit's discipline).
  document,

  /// Source code: "output only the complete raw source file — no fences,
  /// no commentary" (the discipline every code-writing dogfood re-invented).
  source,

  /// No suffix — the prompt owns its own output contract.
  free,
}

/// Authors a FILE: one agent turn whose output becomes the content of
/// [path] — the unstructured sibling of [Produce] (which demands a JSON
/// schema). Extracted from the repeated `Task` + `WriteFile` pair every
/// artifact-producing pipeline hand-rolled.
///
/// ```dart
/// Author(
///   agent: engineer,
///   prompt: Template(['Implement the Task model per:\n', plan]),
///   path: '/project/lib/models/task.dart',
///   output: modelSource,
///   discipline: AuthorDiscipline.source,
/// )
/// ```
class Author extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;
  final Template prompt;

  // Two-form path storage (the `Template` idiom): a const constructor
  // cannot build a Template in an initializer, so the literal and dynamic
  // forms store separately and [path] unifies them.
  final Template? _pathTemplate;
  final String? _literalPath;

  /// The wire carrying the authored content — explicit, so later siblings
  /// (reviews, prompts) can reference what was written.
  final Binding output;

  final AuthorDiscipline discipline;

  /// Dynamic destination — the path itself interpolates bindings (a file
  /// whose location comes from a ticket, a scoped artifact root, …).
  /// Discipline still applies: this is why dynamic-path writes belong
  /// here rather than in a hand-rolled `Task` + `WriteFile` pair, where
  /// the content instruction drifts away from the end of the prompt.
  const Author({
    this.agent,
    this.agentId,
    required this.prompt,
    required Template path,
    required this.output,
    this.discipline = AuthorDiscipline.document,
  }) : _pathTemplate = path,
       _literalPath = null,
       assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  /// Literal destination path — the common case.
  const Author.at(
    String path, {
    this.agent,
    this.agentId,
    required this.prompt,
    required this.output,
    this.discipline = AuthorDiscipline.document,
  }) : _literalPath = path,
       _pathTemplate = null,
       assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  /// The destination, unified across both forms.
  Template get path => _pathTemplate ?? Template.text(_literalPath!);

  static const String _sourceOnly =
      '\n\nOutput ONLY the complete raw source file, starting with its '
      'first directive or declaration — no markdown fences, no commentary.';

  @override
  VasterNode build(BuildContext context) {
    final suffix = switch (discipline) {
      AuthorDiscipline.document => _documentOnly,
      AuthorDiscipline.source => _sourceOnly,
      AuthorDiscipline.free => '',
    };
    return Sequence([
      Task(
        agent: agent,
        agentId: agentId,
        output: output,
        prompt: Template([...prompt.parts, if (suffix.isNotEmpty) suffix]),
      ),
      WriteFile(path: path, content: Template([output])),
    ]);
  }
}

/// Revises an existing file in place against a critique or instructions:
/// reads the CURRENT content, then [Author]s the replacement with both the
/// current source and [addressing] bound into the prompt — the
/// apply-the-review pair every revision pipeline hand-rolled.
///
/// ```dart
/// Revise(
///   agent: engineer,
///   path: '/project/lib/models/task.dart',
///   addressing: Template(['Apply every blocking fix in:\n', review]),
///   output: revisedSource,
/// )
/// ```
class Revise extends ComposableNode {
  final AgentRole? agent;
  final String? agentId;

  /// The file revised in place.
  final String path;

  /// The critique or instructions to address (typically a review binding).
  final Template addressing;

  /// The wire carrying the revised content.
  final Binding output;

  final AuthorDiscipline discipline;

  const Revise({
    this.agent,
    this.agentId,
    required this.path,
    required this.addressing,
    required this.output,
    this.discipline = AuthorDiscipline.source,
  }) : assert(agent == null || agentId == null, 'Provide at most one of agent/agentId');

  @override
  VasterNode build(BuildContext context) {
    final current = context.scopedBinding('revise_current');
    return Sequence([
      ReadFile.at(path, output: current),
      Author.at(
        path,
        agent: agent,
        agentId: agentId,
        output: output,
        discipline: discipline,
        prompt: Template([
          'Revise the file below, addressing everything that follows it. '
              'Do not regress behavior the instructions do not name.\n\n'
              '--- current $path ---\n',
          current,
          '\n\n--- address ---\n',
          ...addressing.parts,
        ]),
      ),
    ]);
  }
}
