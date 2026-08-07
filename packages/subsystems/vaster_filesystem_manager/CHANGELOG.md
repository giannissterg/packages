## Unreleased

- **BREAKING (Rule 11 V4)**: `beginTransaction`/`commit`/`rollback`
  return the transaction depth they left behind; `importTransactions`
  returns the restored depth — the checkpoint-restore audit trail.

- **BREAKING (Rule 11 V1)**: `mount` returns the NORMALIZED prefix —
  the handle resolution actually uses.

- Open transactions export/import (GAP-1): `exportTransactions()` /
  `importTransactions()` serialize the open frames (outermost first, one
  `{mountPrefix: {path: base64}}` per frame) so a checkpoint taken inside
  a `Transaction` resumes with rollback protection intact — Rule 8's
  every-stateful-subsystem-exports pattern.
- **Transactions NEST** (REL-P4): `beginTransaction` pushes a frame;
  `commit`/`rollback` operate on the innermost. The old flat map made an
  inner begin silently clobber the outer snapshot and an inner commit
  erase the outer's ability to roll back. New `transactionDepth` getter —
  the runtime's error unwinding rolls back to it when a failure is caught.

## 0.2.0

- Initial version.
