# Changelog

## Unreleased

- **B5**: `SnapshotHost` facet — the six members checkpoint
  capture/restore actually uses; `MachineCheckpoint.capture` and
  `SessionSnapshot` take the facet, and only `restoreRuntime` (which
  CONSTRUCTS a runtime) keeps the master interface, with the reason in
  its doc.

- **BREAKING (B2, Rule 5)**: `PromptFunnel`'s four verbs take a
  REQUIRED `model` — the caller that owns the selection resolves it.
  `createAgent`'s `model:` override parameter is GONE: an agent's model
  is descriptor configuration (`modelDescriptor`/`modelFallbacks`).

- **BREAKING (R wave)**: `shutdown` returns `VmShutdownReport`;
  `registerSandbox` returns `SandboxRegistration` with fields that say
  what they hold (`displacedSandbox`/`displacedBridgedTool` — the
  record's `sandbox:` read as the registered one). Anonymous records no
  longer cross the master interface (Rule 11).

- **BREAKING (C wave)**: `registerModel` returns EVERY displaced
  binding keyed by slot — registration writes both the descriptor key
  and the bare provider key that `resolveModel` falls back to, so
  reporting one hid a real eviction. `registerSandbox` returns both the
  displaced sandbox AND the displaced bridged tool.

- **A4**: `ModelChainResolver` — THE one composer for declared model
  chains (runtime active model + agent creation), with index-exact
  fallback hop events.

- **A1**: `VasterVirtualMachine.agentToolGate` — the gate binding the
  executing runtime fills with the program's policy guard.

- **BREAKING (Rule 11 V6)**: `shutdown` returns the teardown summary
  (sessions closed, hub/bus closure).

- **BREAKING (Rule 11 V1)**: `ModelRegistry.registerModel` and the
  master interface's `registerModel`/`registerTool`/`registerSandbox`
  return displaced entities; `mountFileSystem` returns the normalized
  prefix; `mountSandbox` returns the sandbox it constructed (previously
  unreachable).

- `VasterVirtualMachine.agentToolRecorder` (GAP-3a): the agent-loop
  effect-recorder binding — agents hold it eagerly, the executing
  runtime binds its ledger adapter into it.

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
