## Unreleased

- **BREAKING (A3)**: durability is a CONTRACT obligation —
  `exportFilesBase64`/`importFilesBase64` join `VasterFileSystem`, so
  `vaster_checkpoint` composes them instead of downcasting (any third
  implementation used to checkpoint as silently empty).
- **BREAKING (B4 fix)**: `writeText`/`writeBytes` return the NORMALIZED
  PATH, not a byte count re-derived from the caller's own argument —
  the fabricated receipt Rule 11 forbids. `restoreSnapshot` returns the
  number of files restored.

- **BREAKING (Rule 11 V4)**: `writeText`/`writeBytes` return the bytes
  written.

## 0.2.0

- Initial version.
