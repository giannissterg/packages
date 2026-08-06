part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Context — what the model knows.
//
// The declarative surface is [Knowledge]: a scope node declaring information
// the model sees while its subtree runs. Lifetime is structural — the region
// mounts on scope entry and unmounts on scope exit, so WHERE you declare
// knowledge in the tree IS how long it lives (declare at the Pipeline root
// for run-long knowledge, inside a phase for phase-long).
//
// The nodes below (AddContext, EvictContext, CompressContext) are the
// LOW-LEVEL heap tier — the lowering targets of Knowledge and ContextBudget.
// Prefer the declarative scopes.
// ══════════════════════════════════════════════════════════════════════════════

/// Declares knowledge the model sees while [child] runs — the declarative
/// context scope.
///
/// Content is [text] (supports `${name}` interpolation) or the value bound
/// to [from]. The region mounts before [child] and unmounts after it; a
/// [pinned] region is cache-hint eligible for its whole scope and is still
/// removed at scope exit.
///
/// ```dart
/// Knowledge(
///   label: 'project brief',
///   text: 'Build a notes app with offline sync.',
///   pinned: true,
///   child: Sequence([...the work grounded in the brief...]),
/// )
/// ```
class Knowledge extends ComposableNode {
  final String label;
  final Template text;
  final Binding? from;

  /// Context class this knowledge belongs to (defaults to `knowledge`).
  /// Policy fields left null inherit from the class.
  final String className;
  final ContextPriority? priority;
  final ContextCompressibility? compressibility;
  final bool pinned;
  final VasterNode child;

  /// Region id override; defaults to a slug derived from [label]. Set it when
  /// two Knowledge scopes share a label.
  final String? id;

  const Knowledge({
    required this.label,
    this.text = const Template.text(''),
    this.from,
    this.className = ContextClassTable.knowledgeClassName,
    this.priority,
    this.compressibility,
    this.pinned = false,
    required this.child,
    this.id,
  });

  String get _regionId =>
      id ?? 'knowledge_${label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

  @override
  VasterNode build(BuildContext context) {
    final regionId = _regionId;
    return Sequence([
      AddContext(
        regionId: regionId,
        label: label,
        text: text.lower(),
        from: from?.name,
        className: className,
        priority: priority,
        compressibility: compressibility,
        pinned: pinned,
      ),
      child,
      // Structural lifetime: the scope's end unmounts the region (force
      // clears pinning — pinning protects against mid-scope eviction, not
      // against the scope itself ending).
      EvictContext(regionId: regionId, force: true),
    ]);
  }
}

/// Declares a token budget for the context heap while [child] runs: the heap
/// is compacted toward [maxTokens] on scope entry (summarizing/truncating
/// regions per their declared compressibility).
///
/// ```dart
/// ContextBudget(
///   maxTokens: 12000,
///   child: Sequence([...long-running work...]),
/// )
/// ```
class ContextBudget extends ComposableNode {
  final int maxTokens;
  final VasterNode child;

  const ContextBudget({required this.maxTokens, required this.child});

  @override
  VasterNode build(BuildContext context) {
    return Sequence([
      CompressContext(targetTokens: maxTokens),
      child,
    ]);
  }
}

/// Declares (or overrides) context classes for the whole program — the
/// segment table of the context linker. Compiles into **static program
/// header metadata**, not instructions: class resolution is lexically
/// scoped to the program, never dependent on execution order.
///
/// The declared classes are layered over the standard table
/// ([ContextClassTable.standard]), so pipelines only state their deltas.
///
/// ```dart
/// ContextClasses(
///   classes: [
///     ContextClass(
///       name: 'domain_docs',
///       band: 22,
///       share: BudgetShare(minFraction: 0.2),
///       cacheStable: true,
///     ),
///   ],
///   child: Sequence([...]),
/// )
/// ```
final class ContextClasses extends VasterNode {
  final List<ContextClass> classes;
  final VasterNode child;

  const ContextClasses({required this.classes, required this.child});
}

// ── Low-level context heap tier ───────────────────────────────────────────────

/// Adds a context region to the VM context heap. Content is [text] (which
/// supports `${name}` interpolation), or the value bound to [from] at
/// runtime when set.
final class AddContext extends VasterNode {
  final String regionId;
  final String label;
  final String text;
  final String? from;

  /// Context class the region belongs to; null resolves to the table's
  /// default class. Null policy fields inherit from the class.
  final String? className;
  final ContextPriority? priority;
  final ContextLifetime? lifetime;
  final ContextCompressibility? compressibility;
  final bool pinned;

  const AddContext({
    required this.regionId,
    required this.label,
    this.text = '',
    this.from,
    this.className,
    this.priority,
    this.lifetime,
    this.compressibility,
    this.pinned = false,
  });
}

/// Removes a context region from the VM context heap.
final class EvictContext extends VasterNode {
  final String regionId;
  final bool force;

  const EvictContext({required this.regionId, this.force = false});
}

/// Low-level: compresses context toward a token target — the lowering target
/// of [ContextBudget], which is the declarative surface. Null [regionId]
/// compacts the whole heap; null [targetTokens] derives from the active
/// model budget. The freed-token count binds to [output].
final class CompressContext extends VasterNode {
  final String? regionId;
  final int? targetTokens;
  final String? output;

  const CompressContext({this.regionId, this.targetTokens, this.output});
}
