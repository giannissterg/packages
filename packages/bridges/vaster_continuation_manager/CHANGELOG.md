# Changelog

## Unreleased

- **BREAKING (C wave)**: `ContinuationStore.clear` returns how many
  snapshots it dropped.

- **BREAKING (Rule 11 V4)**: `saveContinuation` returns the saved
  continuation's id — the handle `loadContinuation` retrieves it by.
