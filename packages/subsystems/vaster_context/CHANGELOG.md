## Unreleased

- C wave: `ContextHeap.clear` returns regions dropped (it sat void
  eight lines under the int-returning `clearNonCritical`).

- Rule 11 V3: `clearNonCritical` returns the number of regions removed.

- **BREAKING (Rule 11 V1)**: `ContextHeap.addRegion`/`replaceRegion`
  return the displaced same-id region; `addAll` the displaced list;
  `upsertFromSource` the region now standing in the heap (fresh /
  shadowing / merged).

## 0.2.0

- Initial version.
