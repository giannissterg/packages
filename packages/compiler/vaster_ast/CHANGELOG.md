# Changelog

## Unreleased

- **BREAKING — W2 (AST_REVIEW F1)**: `Specify.goal` and `Clarify.topic`
  are `Template`-typed. Bound values interpolate as typed `Binding`
  parts; the escaped-dollar string tier is gone from the sugar kit.
  Migration is mechanical: `goal: 'x'` → `goal: Template.text('x')`.
  Lowered prompt strings are byte-identical for pure-text goals —
  recorded envelopes replay unchanged.

- **W2 (AST_REVIEW F7)**: the `Builder` pattern. `Builder<T>` builds a
  subtree from the context-resolved `T` (the consumer counterpart of
  `Provider<T>`); the SDD phases gain `then:` builder slots handing
  their EFFECTIVE output wires to the continuation — `Specify`/`Plan`
  expose their output `Binding`, `Review` a `ReviewOutputs`
  (review + verdict). Resolution happens inside build, so the exposed
  bindings are correctly namespaced by construction.

- **W3 (AST_REVIEW F5)**: `Sdd(root: …, children: […])` scope node —
  SDD conventions for a subtree without the `Provider<SddConventions>`
  spelling.

- **W1 (AST_REVIEW F4)**: `ReadFile.at('/path', output: …)` and
  `WriteFile.at('/path', content: …)` — literal-path convenience without
  the `Template.text` wrapper. Const-safe via the same two-form storage
  `Template` itself uses; `path` remains a `Template` getter, so
  compiler and consumers are unchanged.

- **BREAKING (semantics)**: `Task` is transactional by default (REL-P4) —
  it wraps in `Transaction`, so a failed task's VFS writes roll back and a
  retry starts clean. Opt out with `transactional: false`. `Produce`
  inherits the default through composition.

- `SelectModel` accepts an ordered `fallbacks:` chain (REL-P3): a
  model-kind failure under the scope falls through descriptor by
  descriptor, each tried once. Cancellation never advances the chain;
  retry-same-model remains `Resilient`'s loop — the two compose.

- **BREAKING**: `Resilient` is a first-class node, not a desugar. It
  compiles to the canonical retry LOOP (constant code size — the old
  expansion was O(attempts × child)); the error register is a single
  `retry_error` (was `retry_error_<i>` per attempt).


## 0.3.0

- `nodes.dart` split into part files along its seams: `nodes_declarative`,
  `nodes_context`, `nodes_control_flow`, `nodes_lowering` (same library, no
  API change).
- `ApprovalGate` reads the HITL approval flag via the shared
  `hitlStatusRegister` convention (narrow `show` import of
  `vaster_instruction`).

## 0.2.0

- **Breaking — typed dataflow**: `output:`/`from:` slots take `Binding`;
  prompt/path/content slots take `Template` (const part-lists);
  `When(condition:)` takes `Cond`; `Inputs`/`Pipeline.inputs` are keyed by
  `Binding`. `BindingScope`/`context.scopedBinding` namespace scope-provided
  defaults (SDD phases compose collision-free). `Pipeline(result:)` replaces
  the removed `Output` node.

- **Breaking — declarative-only default import**: imperative primitives
  live in `package:vaster_ast/primitives.dart`; compiler lowering targets in
  `package:vaster_ast/lowering.dart`. The main import is the declarative
  tier only.
- **Breaking — scope providers take `child:`**: `ToolSet`, `Mount`,
  `Sandbox`, `SelectModel`, `BudgetScope`, `Inputs` (matching
  `Agent`/`Knowledge`/`ContextBudget`); wrap former sibling lists in
  `Sequence`. Omitting `child` provisions/declares without scoping.

Breaking DX overhaul — see the root CHANGELOG for the full narrative.

- Vocabulary unified (`prompt`, `condition`, `counter`, `error`, `output`,
  `from`); `Agent(child:)` single-subtree provider; `Pipeline(name:)` with
  real provisioning of declared roles/mounts/tools/model.
- New: `output:` bindings + `${...}` interpolation, `Inputs`, `Extract`,
  `Sequence`, `Decide`/`DecideLoop`, `Knowledge`, `ContextBudget`, the
  coordination library (`AgentTeam`, `FanOut`, `RefineLoop`, `Router`,
  `Resilient`, `Produce`), and the SDD kit (`Clarify`, `Specify`, `Plan`,
  `Review`, `Implement`, `Verify`).
- Removed: `PinContext`, `UnpinContext`, `ContextPolicy`, the
  `ProviderNode` typedef, and Flutter demo components (moved to
  `vaster_playground`).
- Design rules documented in-source: nest vs sequence, and the base-node
  admission test (sugar lowering targets only).

## 0.0.1

- Initial version.
