import 'context_compressibility.dart';
import 'context_lifetime.dart';
import 'context_priority.dart';

/// How a context class sheds tokens under budget pressure, once compression
/// (when permitted) has been exhausted.
enum EvictionPolicy {
  /// Compress members first (per their compressibility), then fall back to
  /// [dropLowestUtility].
  compressFirst,

  /// Evict the earliest-ordered members first (chronological shedding —
  /// natural for history).
  dropOldest,

  /// Evict the lowest-utility members first.
  dropLowestUtility,

  /// Members are never shed. A [never] class that cannot fit its content is a
  /// hard allocation error — silently truncating it would be dishonest.
  never;

  static EvictionPolicy parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final p in EvictionPolicy.values) {
      if (p.name.toLowerCase() == lower) return p;
    }
    return EvictionPolicy.dropLowestUtility;
  }
}

/// Budget contract for one context class — cgroups semantics: a hard
/// reservation (guaranteed floor), a cap (ceiling), and a weight for
/// distributing surplus between classes.
///
/// Token amounts and window fractions may both be given; the effective bound
/// is the larger floor / smaller ceiling of the two.
class BudgetShare {
  /// Guaranteed minimum tokens (absolute).
  final int? minTokens;

  /// Guaranteed minimum as a fraction of the available window (0..1).
  final double? minFraction;

  /// Maximum tokens this class may occupy (absolute).
  final int? maxTokens;

  /// Maximum as a fraction of the available window (0..1).
  final double? maxFraction;

  /// Relative weight for surplus distribution among classes that still have
  /// headroom after reservations. 0 = never receives surplus.
  final double weight;

  const BudgetShare({
    this.minTokens,
    this.minFraction,
    this.maxTokens,
    this.maxFraction,
    this.weight = 1.0,
  });

  /// No reservation, no cap, weight 1 — competes for surplus only.
  static const BudgetShare unreserved = BudgetShare();

  /// Effective guaranteed floor for a window of [availableTokens].
  int floorFor(int availableTokens) {
    final fromFraction =
        minFraction != null ? (minFraction! * availableTokens).floor() : 0;
    final fromTokens = minTokens ?? 0;
    return fromTokens > fromFraction ? fromTokens : fromFraction;
  }

  /// Effective ceiling for a window of [availableTokens]; null = uncapped.
  int? ceilingFor(int availableTokens) {
    final fromFraction =
        maxFraction != null ? (maxFraction! * availableTokens).floor() : null;
    if (maxTokens == null) return fromFraction;
    if (fromFraction == null) return maxTokens;
    return maxTokens! < fromFraction ? maxTokens : fromFraction;
  }

  List<String> validate(String owner) => [
        if (minFraction != null && (minFraction! < 0 || minFraction! > 1))
          '$owner: minFraction must be in [0,1]',
        if (maxFraction != null && (maxFraction! < 0 || maxFraction! > 1))
          '$owner: maxFraction must be in [0,1]',
        if (minTokens != null && minTokens! < 0)
          '$owner: minTokens must be >= 0',
        if (maxTokens != null && maxTokens! < 0)
          '$owner: maxTokens must be >= 0',
        if (minTokens != null && maxTokens != null && minTokens! > maxTokens!)
          '$owner: minTokens exceeds maxTokens',
        if (minFraction != null &&
            maxFraction != null &&
            minFraction! > maxFraction!)
          '$owner: minFraction exceeds maxFraction',
        if (weight < 0) '$owner: weight must be >= 0',
      ];

  Map<String, dynamic> toJson() => {
        if (minTokens != null) 'minTokens': minTokens,
        if (minFraction != null) 'minFraction': minFraction,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (maxFraction != null) 'maxFraction': maxFraction,
        if (weight != 1.0) 'weight': weight,
      };

  factory BudgetShare.fromJson(Map<String, dynamic> json) => BudgetShare(
        minTokens: json['minTokens'] as int?,
        minFraction: (json['minFraction'] as num?)?.toDouble(),
        maxTokens: json['maxTokens'] as int?,
        maxFraction: (json['maxFraction'] as num?)?.toDouble(),
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
      );
}

/// A named allocation class for context regions — the segment descriptor of
/// the context "linker": placement band, budget contract, policy defaults.
///
/// Regions reference a class by name and may override individual policy
/// fields; the class supplies defaults (see `ContextRegion` nullable policy
/// fields).
class ContextClass {
  /// Unique class name.
  final String name;

  /// Placement band: the compiled context is laid out band-ascending, so low
  /// bands form the (cacheable) prefix and high bands the volatile tail.
  final int band;

  /// Budget contract.
  final BudgetShare share;

  /// Default priority for member regions (admission ordering within
  /// volatile classes).
  final ContextPriority priority;

  /// Default lifetime for member regions.
  final ContextLifetime lifetime;

  /// Default compressibility for member regions.
  final ContextCompressibility compressibility;

  /// How this class sheds tokens under pressure.
  final EvictionPolicy eviction;

  /// Prefix-stable segment: admission and layout inside this class must be a
  /// deterministic function of the class's own content only — global budget
  /// pressure may never reorder or selectively evict it (it can only shed via
  /// this class's own policy). This is what keeps KV/prompt-cache prefixes
  /// valid across compiles.
  final bool cacheStable;

  /// Members behave as pinned for allocation unless a region explicitly
  /// unpins itself. (Stored region pinning stays an explicit runtime action;
  /// this is an allocation-time default.)
  final bool pinnedByDefault;

  const ContextClass({
    required this.name,
    required this.band,
    this.share = BudgetShare.unreserved,
    this.priority = ContextPriority.medium,
    this.lifetime = ContextLifetime.session,
    this.compressibility = ContextCompressibility.none,
    this.eviction = EvictionPolicy.dropLowestUtility,
    this.cacheStable = false,
    this.pinnedByDefault = false,
  });

  List<String> validate() => [
        if (name.isEmpty) 'class name must be non-empty',
        ...share.validate(name),
      ];

  Map<String, dynamic> toJson() => {
        'name': name,
        'band': band,
        if (share.toJson().isNotEmpty) 'share': share.toJson(),
        if (priority != ContextPriority.medium) 'priority': priority.name,
        if (lifetime != ContextLifetime.session) 'lifetime': lifetime.name,
        if (compressibility != ContextCompressibility.none)
          'compressibility': compressibility.name,
        if (eviction != EvictionPolicy.dropLowestUtility)
          'eviction': eviction.name,
        if (cacheStable) 'cacheStable': cacheStable,
        if (pinnedByDefault) 'pinnedByDefault': pinnedByDefault,
      };

  factory ContextClass.fromJson(Map<String, dynamic> json) => ContextClass(
        name: json['name'] as String? ?? '',
        band: json['band'] as int? ?? 0,
        share: json['share'] != null
            ? BudgetShare.fromJson(
                Map<String, dynamic>.from(json['share'] as Map))
            : BudgetShare.unreserved,
        priority:
            ContextPriority.parse(json['priority'] as String? ?? 'medium'),
        lifetime: ContextLifetime.parse(json['lifetime'] as String? ?? 'session'),
        compressibility: ContextCompressibility.parse(
            json['compressibility'] as String? ?? 'none'),
        eviction: EvictionPolicy.parse(
            json['eviction'] as String? ?? 'dropLowestUtility'),
        cacheStable: json['cacheStable'] as bool? ?? false,
        pinnedByDefault: json['pinnedByDefault'] as bool? ?? false,
      );

  @override
  String toString() =>
      'ContextClass($name, band: $band, ${cacheStable ? 'stable' : 'volatile'})';
}

/// The segment table: every context class known to a program or manager.
///
/// Static metadata — installed at construction (host) or carried in the
/// program header (bytecode), never mutated by executing instructions.
/// Regions with no [ContextRegion.classId] (or an unknown one) resolve to
/// [defaultClassName].
class ContextClassTable {
  final Map<String, ContextClass> classes;

  /// The class that classless regions resolve to. Must exist in [classes].
  final String defaultClassName;

  const ContextClassTable({
    required this.classes,
    this.defaultClassName = generalClassName,
  });

  // Canonical class names (the model-ABI segments plus the neutral default).
  static const String systemClassName = 'system';
  static const String toolsClassName = 'tools';
  static const String knowledgeClassName = 'knowledge';
  static const String historyClassName = 'history';
  static const String generalClassName = 'general';
  static const String scratchClassName = 'scratch';

  /// The standard segment table. Bands: system(0) < tools(10) <
  /// knowledge(20) < general(25) < history(30) < scratch(90) — ambient
  /// content renders before conversation history (history is the volatile
  /// tail, chronologically last). The model's inherent structure (system
  /// slot, tool schemas, output reservation) is expressed as reserved
  /// classes; `output` is a pure reservation handled by `TokenBudget`, not a
  /// content class.
  static const ContextClassTable standard = ContextClassTable(
    classes: {
      systemClassName: ContextClass(
        name: systemClassName,
        band: 0,
        eviction: EvictionPolicy.never,
        cacheStable: true,
        pinnedByDefault: true,
      ),
      toolsClassName: ContextClass(
        name: toolsClassName,
        band: 10,
        eviction: EvictionPolicy.never,
        cacheStable: true,
        pinnedByDefault: true,
      ),
      knowledgeClassName: ContextClass(
        name: knowledgeClassName,
        band: 20,
        share: BudgetShare(weight: 2.0),
        compressibility: ContextCompressibility.summarize,
        eviction: EvictionPolicy.compressFirst,
        cacheStable: true,
      ),
      historyClassName: ContextClass(
        name: historyClassName,
        band: 30,
        share: BudgetShare(weight: 3.0),
        compressibility: ContextCompressibility.summarize,
        eviction: EvictionPolicy.dropOldest,
      ),
      generalClassName: ContextClass(
        name: generalClassName,
        band: 25,
      ),
      scratchClassName: ContextClass(
        name: scratchClassName,
        band: 90,
        share: BudgetShare(maxFraction: 0.25),
        lifetime: ContextLifetime.ephemeral,
        compressibility: ContextCompressibility.truncate,
      ),
    },
  );

  /// Resolves a region's class: unknown/absent ids land in the default class
  /// rather than failing — static verification of *program-declared* class
  /// references is the compiler's job, not the allocator's.
  ContextClass resolve(String? classId) =>
      classes[classId] ?? classes[defaultClassName]!;

  /// Whether [classId] names a declared class.
  bool contains(String classId) => classes.containsKey(classId);

  /// Classes in deterministic layout order: `(band, name)`.
  List<ContextClass> get inBandOrder {
    final sorted = classes.values.toList()
      ..sort((a, b) {
        final byBand = a.band.compareTo(b.band);
        return byBand != 0 ? byBand : a.name.compareTo(b.name);
      });
    return sorted;
  }

  /// Sum of hard reservations for a window of [availableTokens] — audit uses
  /// this to report the minimum viable window.
  int totalReservedFor(int availableTokens) => classes.values
      .fold(0, (sum, c) => sum + c.share.floorFor(availableTokens));

  /// A new table with [overrides] layered on top (same names replace, new
  /// names extend).
  ContextClassTable withOverrides(Iterable<ContextClass> overrides) =>
      ContextClassTable(
        classes: {
          ...classes,
          for (final c in overrides) c.name: c,
        },
        defaultClassName: defaultClassName,
      );

  /// Structural issues in this table; empty means valid.
  List<String> validate() => [
        for (final entry in classes.entries) ...[
          if (entry.key != entry.value.name)
            'table key "${entry.key}" does not match class name '
                '"${entry.value.name}"',
          ...entry.value.validate(),
        ],
        if (!classes.containsKey(defaultClassName))
          'default class "$defaultClassName" is not declared',
      ];

  Map<String, dynamic> toJson() => {
        'classes': [for (final c in inBandOrder) c.toJson()],
        if (defaultClassName != generalClassName)
          'defaultClassName': defaultClassName,
      };

  factory ContextClassTable.fromJson(Map<String, dynamic> json) {
    final classList = (json['classes'] as List? ?? [])
        .whereType<Map>()
        .map((m) => ContextClass.fromJson(Map<String, dynamic>.from(m)));
    return ContextClassTable(
      classes: {for (final c in classList) c.name: c},
      defaultClassName:
          json['defaultClassName'] as String? ?? generalClassName,
    );
  }
}
