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
