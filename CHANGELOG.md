# Changelog

## 0.2.0

Breaking DX overhaul of the AST surface, plus new runtime semantics.

- **`${name}` interpolation is now real ISA semantics**: prompts, task
  prompts, file paths/content, sandbox code, context text, and message
  payloads resolve register references at runtime. Unresolvable references
  stay verbatim and surface as runtime warnings; the compiler warns on
  unbound references at compile time.
- **Named outputs**: every value-producing node accepts `output:`.
- **Breaking renames**: `Task(prompt:, agent:/agentId:)` (was
  `taskPrompt`/`agentRoleId`), `While(condition:)`, `Repeat(counter:)`,
  `TryCatch(error:)`, `Output(from:)`, `AddContext(from:)`,
  `SendMessage(to:/toId:/from:/fromId:)`; `Agent` wraps a single `child:`.
- **`Pipeline(name:)`** shorthand; `roles`/`mounts`/`tools`/`model` now
  provision for real. New `Inputs`, `Extract`, `Sequence` nodes.
- **Model-steered control flow**: `Decide`, `DecideLoop` (bounded agency).
- **Coordination library**: `AgentTeam`, `FanOut`, `RefineLoop`, `Router`,
  `Resilient`, `Produce`.
- **SDD workflow kit**: `Clarify → Specify → Plan → Review → Implement →
  Verify` with markdown artifacts as the coordination medium.
- **Declarative context**: `Knowledge` (structural lifetime scope),
  `ContextBudget`. Removed the dead `PinContext`/`UnpinContext`/
  `ContextPolicy` AST nodes (ISA ops remain) and `TaskDefinition`.
- Runtime: virtual-core concurrent scheduling, subroutine call-stack
  continuations, tool/sandbox/decision telemetry, disk mounts honored,
  sandbox timeouts enforced.
- CLI: `vaster compile`, `vaster run --record/--events`, and the
  claude-cli/gemini-cli/rpc backends.
- **Runtime honesty**: `SetQuotaOp` is enforced — program-declared token
  budgets, deadlines, and tool-call ceilings bind from the instruction they
  execute at (breaches are catchable by `TryCatch`, otherwise trap); declared
  cost ceilings publish a `cost_quota_unenforced` warning until a backend
  reports cost. Unknown ISA opcodes now fail decoding loudly instead of
  silently becoming empty prompts. **Breaking**: the HITL `<output>_status`
  register is now a boolean (affirmative vs not) instead of the raw status
  name, and the `JumpIf` truthiness table no longer special-cases
  `approved`/`rejected` strings.
- VFS: `MemoryVasterFileSystem` text I/O is UTF-8 (was UTF-16 code units
  truncated to bytes — every codepoint above U+00FF was mangled on the
  write/read round-trip, discovered when a real-model SDD run had its plan's
  em-dashes and box-drawing characters corrupted between Plan and Review).
  `VirtualFile.text` decodes UTF-8 accordingly.
- SDD: the review-verdict decide prompt now instructs the model to judge only
  from the review text — a real claude-cli calibration run showed backends
  without schema enforcement re-reviewing the artifact and overriding the
  reviewer's verdict.
- Consolidation: the recorded real-model SDD run is now a committed replay
  fixture (`sdd_fidelity.replay.json`) — a zero-cost CI lock asserting the
  frontend still lowers to the exact prompts the model saw and that usage
  accounting replays to the token (450,302) and the cent ($0.825917).
  `vaster run --cores` exposes the VM's virtual core count. Composable
  `build()` expansions gained direct unit coverage in vaster_ast.
  Note: the installed gemini CLI hangs headless (auth-gated), so its live
  stats schema remains unverified; the parser handles both known schemas.
- **Typed dataflow** (`Binding` / `Template` / `Cond`): the declarative
  tier's stringly register plumbing is gone. `output:` slots take `Binding`
  objects (the wire compiles away to an ISA register — Rule 1 intact);
  prompts/paths/content are `Template` const part-lists mixing text and
  bindings (unresolvable references are structurally impossible; raw `${}`
  in a template warns); `When` takes `Cond.isTrue/equals/notEquals/not`
  lowering onto existing CompareRegisterOp/JumpIf. `BindingScope` +
  `context.scopedBinding` distribute defaults (SDD phases namespace their
  bindings and artifact paths — two SDD cycles now compose collision-free,
  closing backlog #6). `Pipeline(result:)` declares the program result in
  the header (VBC v2 header generalized to a map), retiring the `Output`
  node and `__output__` register convention (backlog #8). Verified by
  replaying the recorded real-model SDD tape against the recompiled typed
  pipeline — byte-identical prompts, full replay hit.
- **AST DX — declarative surface** (Flutter-style): the default
  `package:vaster_ast/vaster_ast.dart` import now contains no imperative
  nodes. Low-level primitives (`AddContext`, `EvictContext`,
  `CompressContext`, `YieldHuman`, `While`, `Repeat`, `TryCatch`,
  `DefineSubroutine`, `CallSubroutine`) moved to the opt-in
  `package:vaster_ast/primitives.dart`; compiler lowering targets
  (`*Header`, `*Execution`, `PipelineBody`) moved to
  `package:vaster_ast/lowering.dart` (vaster_compiler-internal). Scope
  providers unified on a single `child:` like `Agent`/`Knowledge`:
  `ToolSet`, `Mount`, `Sandbox`, `SelectModel`, `BudgetScope`, and `Inputs`
  now take `child:` (breaking; wrap former sibling lists in `Sequence`).
- **Context class system**: context is now managed like memory — the
  compiled prompt is *linked*, not concatenated. New `ContextClass` /
  `BudgetShare` / `ContextClassTable` primitives (segment table with bands,
  cgroups-style hard-min/soft-weight shares, per-class eviction policies,
  cache-stable segments); a class-aware allocation strategy with
  deterministic `(band, order, id)` layout, reservation-then-weighted-surplus
  admission, tail-only cuts for cache-stable bands, and a hard
  `ContextOverflowError` for unevictable overflow (previously admitted
  silently past the window). Region policy fields became nullable overrides
  inheriting from their class. Class tables are static program-header
  metadata (`VasterProgram.contextClasses`, VBC format v2) declared via the
  `ContextClasses` AST node — never instructions; the analyzer rejects
  undefined class references and `vaster audit` prints the segment map.
  ABI wiring: agent system instructions finally reach
  `ModelRequest.systemInstruction` (multiple system regions concatenate
  instead of dropping), tool reservations derive from real definitions,
  session-path cache hints are no longer dropped, and compaction respects
  class policy (system class is immutable).
- **Usage fidelity**: `UsageMetadata` gained cache read/write and thought
  token breakdowns, wire-reported `costUsd`, and a measured-vs-estimated
  `source` marker; every backend parser reports full-fidelity usage
  (claude-cli no longer drops cache tokens and `total_cost_usd`; claude-api
  streaming parses `message_start`; the RPC sidecar carries usage on stream
  chunks; gemini-cli handles both stats schemas; llama.cpp counts
  `tokens_cached`). `AgentOutput` carries per-tree usage, so agent dispatch
  charges real numbers and parallel dispatch is no longer free. Streaming
  (`vm.promptStream`) is metered. New packages: `vaster_token_estimate` (the
  one sanctioned `/4` heuristic, always labeled estimated) and
  `vaster_pricing` (`PricingCatalog` rate tables; wire-reported cost wins) —
  cost ceilings now bind, and `cost_quota_unenforced` fires only for
  genuinely unpriced backends. New `ModelUsageEvent` telemetry (one per
  model call) and a `vaster run` report with cost and cache-share lines.

## 0.0.1

- Initial version.
