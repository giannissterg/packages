## Unreleased

- `SelectModelHeader` lowering carries the fallback chain into
  `SelectModelOp` (REL-P3), and `CapabilityAudit` lists declared chains:
  every member joins `models`, and `modelChains` renders each chain in
  declaration order (`primary → fb1 → fb2`).

## 0.2.0

- Initial version.
