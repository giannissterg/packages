## Unreleased

- **Transactions NEST** (REL-P4): `beginTransaction` pushes a frame;
  `commit`/`rollback` operate on the innermost. The old flat map made an
  inner begin silently clobber the outer snapshot and an inner commit
  erase the outer's ability to roll back. New `transactionDepth` getter —
  the runtime's error unwinding rolls back to it when a failure is caught.

## 0.2.0

- Initial version.
