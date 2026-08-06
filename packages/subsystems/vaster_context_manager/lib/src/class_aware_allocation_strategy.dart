import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

import 'allocation_strategy.dart';

/// Class-aware context "linker": lays regions out as segments defined by a
/// [ContextClassTable].
///
/// Semantics (see the context-class design invariants):
///
/// - **Unconditional admissions** (`never`-eviction classes, effectively
///   pinned regions, `critical` priority) are charged first; if they alone
///   exceed the window, allocation throws [ContextOverflowError] — the
///   over-budget context is a link error, not a silent truncation.
/// - **Phase A — reservations**: each class admits members up to its
///   [BudgetShare] floor, in class-local order.
/// - **Phase B — weighted surplus**: the remaining window is distributed
///   across classes with unmet demand by share weight (waterfill), capped by
///   each class's ceiling.
/// - **Cache-stable classes** admit a deterministic `(order, id)`-prefix of
///   their members — admission is a function of the class's own content only,
///   and any budget cut is a *tail* cut, so the rendered byte-prefix of the
///   band survives global pressure. Utility never influences a stable band.
/// - **Layout** is `(band, order, id)` ascending — fully deterministic.
///   `system`-class regions (and any admitted `Role.system` messages) are
///   concatenated into [CompiledContext.systemInstruction] in layout order;
///   multiple system regions concatenate instead of silently dropping.
/// - Sizes are estimates: [allocationSlack] holds back a safety margin.
class ClassAwareAllocationStrategy implements AllocationStrategy {
  final ContextClassTable classTable;

  /// Named safety margin over estimated sizes (fraction of the available
  /// input budget actually allocated).
  final double allocationSlack;

  const ClassAwareAllocationStrategy({
    required this.classTable,
    this.allocationSlack = 0.9,
  });

  @override
  CompiledContext allocate({
    required List<ContextRegion> regions,
    required TokenBudget budget,
  }) {
    final window = (budget.availableInputBudget * allocationSlack).floor();

    // Group members by resolved class, preserving heap order for tie-breaks.
    final byClass = <String, List<ContextRegion>>{};
    for (final region in regions) {
      final cls = classTable.resolve(region.classId);
      byClass.putIfAbsent(cls.name, () => []).add(region);
    }

    final admitted = <ContextRegion>[];
    final admittedIds = <String>{};
    var admittedTokens = 0;

    // ── Unconditional admissions ────────────────────────────────────────────
    final unevictableTokensByClass = <String, int>{};
    for (final entry in byClass.entries) {
      final cls = classTable.resolve(entry.key);
      for (final region in entry.value) {
        final unconditional = cls.eviction == EvictionPolicy.never ||
            region.effectivePinned(cls) ||
            region.effectivePriority(cls) == ContextPriority.critical;
        if (unconditional) {
          admitted.add(region);
          admittedIds.add(region.id);
          admittedTokens += region.estimatedTokens;
          unevictableTokensByClass[cls.name] =
              (unevictableTokensByClass[cls.name] ?? 0) +
                  region.estimatedTokens;
        }
      }
    }
    if (admittedTokens > window) {
      throw ContextOverflowError(
        requiredTokens: admittedTokens,
        windowTokens: window,
        offendingClasses: unevictableTokensByClass.keys.toList()..sort(),
      );
    }

    // Class-local admission preference order for the remaining members.
    List<ContextRegion> admissionOrder(
        ContextClass cls, List<ContextRegion> members) {
      final pending =
          members.where((r) => !admittedIds.contains(r.id)).toList();
      if (cls.cacheStable) {
        // Deterministic (order, id) prefix — never utility-driven.
        pending.sort(_byOrderThenId);
      } else if (cls.eviction == EvictionPolicy.dropOldest) {
        // Keep newest under pressure: admit from the chronological tail.
        pending.sort(_byOrderThenId);
        return pending.reversed.toList();
      } else {
        pending.sort((a, b) {
          final byPriority = b
              .effectivePriority(cls)
              .index
              .compareTo(a.effectivePriority(cls).index);
          if (byPriority != 0) return byPriority;
          final byUtility = b.utility.compareTo(a.utility);
          if (byUtility != 0) return byUtility;
          return a.id.compareTo(b.id);
        });
      }
      return pending;
    }

    // ── Phase A: reservations ───────────────────────────────────────────────
    final classAdmittedTokens = <String, int>{
      for (final name in byClass.keys) name: 0,
    }..addAll(unevictableTokensByClass);

    for (final entry in byClass.entries) {
      final cls = classTable.resolve(entry.key);
      final floor = cls.share.floorFor(window);
      if (floor <= 0) continue;
      for (final region in admissionOrder(cls, entry.value)) {
        final classTokens = classAdmittedTokens[cls.name] ?? 0;
        if (classTokens >= floor) break;
        if (classTokens + region.estimatedTokens > floor ||
            admittedTokens + region.estimatedTokens > window) {
          // Region straddles the reservation boundary: cache-stable bands cut
          // at the tail (no leapfrogging — that would churn the prefix);
          // volatile classes may pack smaller members into the remainder.
          if (cls.cacheStable) break;
          continue;
        }
        admitted.add(region);
        admittedIds.add(region.id);
        admittedTokens += region.estimatedTokens;
        classAdmittedTokens[cls.name] = classTokens + region.estimatedTokens;
      }
    }

    // ── Phase B: weighted surplus (waterfill) ───────────────────────────────
    // Demand per class = unadmitted member tokens, capped by ceiling headroom.
    int demandOf(String name) {
      final cls = classTable.resolve(name);
      final ceiling = cls.share.ceilingFor(window);
      final used = classAdmittedTokens[name] ?? 0;
      final headroom =
          ceiling == null ? window : (ceiling - used).clamp(0, window);
      var pendingTokens = 0;
      for (final r in byClass[name]!) {
        if (!admittedIds.contains(r.id)) pendingTokens += r.estimatedTokens;
      }
      return pendingTokens < headroom ? pendingTokens : headroom;
    }

    var surplus = window - admittedTokens;
    final quota = <String, int>{for (final name in byClass.keys) name: 0};
    // Waterfill: classes whose demand is below their weighted share release
    // the difference back to the pool; loop until stable (bounded by class
    // count since each round finalizes at least one class).
    var active = byClass.keys.where((n) => demandOf(n) > 0).toList()..sort();
    while (surplus > 0 && active.isNotEmpty) {
      final totalWeight = active.fold<double>(
          0, (s, n) => s + classTable.resolve(n).share.weight);
      if (totalWeight <= 0) break;
      var distributed = 0;
      final stillActive = <String>[];
      for (final name in active) {
        final weight = classTable.resolve(name).share.weight;
        final offer = (surplus * weight / totalWeight).floor();
        final demand = demandOf(name) - quota[name]!;
        final granted = offer < demand ? offer : demand;
        quota[name] = quota[name]! + granted;
        distributed += granted;
        if (granted >= offer && demand > granted) stillActive.add(name);
      }
      if (distributed == 0) break;
      surplus -= distributed;
      active = stillActive;
    }

    for (final name in byClass.keys) {
      final cls = classTable.resolve(name);
      var allowance = quota[name] ?? 0;
      if (allowance <= 0) continue;
      for (final region in admissionOrder(cls, byClass[name]!)) {
        if (region.estimatedTokens > allowance) {
          if (cls.cacheStable) break; // tail cut only — keep the prefix intact
          continue;
        }
        if (admittedTokens + region.estimatedTokens > window) break;
        admitted.add(region);
        admittedIds.add(region.id);
        admittedTokens += region.estimatedTokens;
        allowance -= region.estimatedTokens;
        classAdmittedTokens[name] =
            (classAdmittedTokens[name] ?? 0) + region.estimatedTokens;
      }
    }

    // ── Evictions ───────────────────────────────────────────────────────────
    final evicted = <ContextRegion>[];
    final evictionRecords = <EvictionRecord>[];
    final classEvicted = <String, List<int>>{};
    for (final region in regions) {
      if (admittedIds.contains(region.id)) continue;
      evicted.add(region);
      final clsName = classTable.resolve(region.classId).name;
      classEvicted.putIfAbsent(clsName, () => [0, 0]);
      classEvicted[clsName]![0]++;
      classEvicted[clsName]![1] += region.estimatedTokens;
      evictionRecords.add(EvictionRecord(
        regionId: region.id,
        reason: EvictionReason.budgetExceeded,
        regionTokens: region.estimatedTokens,
        tokensAvailableAtDecision:
            (window - admittedTokens).clamp(0, window),
      ));
    }

    // ── Layout: (band, order, id) ───────────────────────────────────────────
    final layout = List<ContextRegion>.of(admitted)
      ..sort((a, b) {
        final bandDiff = classTable
            .resolve(a.classId)
            .band
            .compareTo(classTable.resolve(b.classId).band);
        if (bandDiff != 0) return bandDiff;
        return _byOrderThenId(a, b);
      });

    // System instruction: concatenate every admitted Role.system message in
    // layout order (system-class regions sort first via band 0).
    final systemTexts = <String>[];
    final compiledMessages = <ChatMessage>[];
    for (final region in layout) {
      final isSystemClass =
          classTable.resolve(region.classId).name ==
              ContextClassTable.systemClassName;
      for (final msg in region.messages) {
        if (msg.role == Role.system || isSystemClass) {
          final text = msg.text.trim();
          if (text.isNotEmpty) systemTexts.add(text);
        } else {
          compiledMessages.add(msg);
        }
      }
    }
    final systemInstruction = systemTexts.isEmpty
        ? null
        : ChatMessage(
            role: Role.system, parts: [TextPart(systemTexts.join('\n\n'))]);

    return CompiledContext(
      systemInstruction: systemInstruction,
      messages: compiledMessages,
      totalEstimatedTokens: admittedTokens,
      budget: budget,
      includedRegions: layout,
      evictedRegions: evicted,
      evictionRecords: evictionRecords,
      classUsage: {
        for (final name in byClass.keys.toList()..sort())
          name: ContextClassUsage(
            admittedRegions: byClass[name]!
                .where((r) => admittedIds.contains(r.id))
                .length,
            admittedTokens: classAdmittedTokens[name] ?? 0,
            evictedRegions: classEvicted[name]?[0] ?? 0,
            evictedTokens: classEvicted[name]?[1] ?? 0,
          ),
      },
    );
  }

  static int _byOrderThenId(ContextRegion a, ContextRegion b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
  }
}
