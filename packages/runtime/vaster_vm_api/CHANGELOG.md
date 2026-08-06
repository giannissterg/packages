# Changelog

## Unreleased

- Capability facets carved out of the master interface (ISP): `PromptFunnel`
  (the four model-turn verbs, carrying the compiled-context contract) and
  `ToolLoopHost` (funnel + tool table + event bus + VFS — what the runtime's
  tool loop needs). `VasterVirtualMachine` implements both; collaborators
  with a bounded job depend on a facet, so their type documents what they
  can actually do.
- **BREAKING**: `VfsSyscalls.writeFile`/`readFile` take the
  `FileSystemManager` instead of the whole VM — the syscall only touches
  the VFS, and now its signature only asks for it.
- **The compiled-context semantics are interface contract now (F3)** —
  the prompt-turn contracts live on `PromptFunnel`; `createSession`'s stays
  on the master interface.

## 0.3.0

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
