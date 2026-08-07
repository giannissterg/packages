## Unreleased

- **BREAKING (Rule 11 V1)**: `addRegion` returns the displaced region,
  `registerSource` the displaced source, `installClassTable` the table
  it replaced — on the interface and both managers.

## 0.3.0

- `SummarizingCompressor` gains an `onUsage` hook reporting each
  summarization call's token usage to its owner — compaction is no longer
  invisible to metering.

## 0.2.0

- Initial version.
