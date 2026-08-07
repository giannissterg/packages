## Unreleased

- Rule 11 V7: eviction telemetry helpers return the published event id.

- **BREAKING (Rule 11 V3)**: `pinRegion`/`unpinRegion` return the
  region as (un)pinned (null when absent), `pruneLifetimes` returns its
  freed report (ids + tokens; an empty report is an observable "pruned
  nothing"), `syncSources` the number of regions upserted.

- **BREAKING (Rule 11 V1)**: `addRegion` returns the displaced region,
  `registerSource` the displaced source, `installClassTable` the table
  it replaced — on the interface and both managers.

## 0.3.0

- `SummarizingCompressor` gains an `onUsage` hook reporting each
  summarization call's token usage to its owner — compaction is no longer
  invisible to metering.

## 0.2.0

- Initial version.
