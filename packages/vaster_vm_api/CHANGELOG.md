# Changelog

## Unreleased

- `VfsSyscalls`: the single implementation of the built-in
  `write_file`/`read_file` tools, shared by the runtime's policy-gated tool
  loop and the VM bootstrap registrations.
- `VasterVirtualMachine.defaultRootAgentId` names the `runAgentTask`
  fallback-agent convention.

## 0.2.0

- Initial version: `VasterVirtualMachine`, `VMConfig`, and `ModelRegistry`
  extracted from `vaster_vm` to break the runtime ⇄ vm dependency cycle —
  the runtime now depends on this interface package only; host-facing job
  scheduling stays on the engine.
