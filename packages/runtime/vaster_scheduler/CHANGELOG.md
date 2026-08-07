# Changelog

## Unreleased

- **BREAKING (B2, Rule 5)**: `submitTask`/`scheduleOpcode` take a
  required `budget` (the hidden `?? unlimited()` default is gone —
  a scheduler silently granting unlimited capacity was the smell).

- C wave: `PriorityTaskQueue.clear` returns tasks dropped.
