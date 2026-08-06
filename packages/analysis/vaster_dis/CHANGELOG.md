## Unreleased

- `SELECT_MODEL` disassembly renders declared fallback chains in order
  (`google_ai:pro → google_ai:flash → fake:local`).

## 0.3.0

- `ExecutionTracer` moved here from `vaster_runtime` behind the dedicated
  `package:vaster_dis/tracer.dart` entrypoint — the core disassembler barrel
  stays runtime-free.

## 0.2.0

- Initial version.
