## Unreleased

- **BREAKING**: `VasterRuntime` builds its full collaborator graph eagerly in
  a factory constructor (no `late final` lazy initialization); metering routes
  through one `ModelCallMeter` (host budget + program quota) instead of six
  hand-rolled charge sites.
- **BREAKING**: depends on `vaster_vm_api` instead of `vaster_vm` — the
  runtime ⇄ vm cycle is gone; all previously barrel-hidden dependencies are
  declared explicitly.
- **BREAKING**: `ExecutionTracer` moved to `package:vaster_dis/tracer.dart`.
- `DispatchParallelTasksOp` works against any `AgentManager` (interface
  method, no more downcast + silent skip) and gives each parallel dispatch a
  unique `parallel_<pc>_<i>` taskId.
- Cache hints forwarded to dispatched agents are now applied (previously
  packed into task metadata and dropped).

## 0.2.0

- Initial version.
