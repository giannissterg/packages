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

## 0.0.1

- Initial version.
