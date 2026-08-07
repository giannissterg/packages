# Vaster ISA — reference & conformance specification, version 1

_Status: normative. Reference implementation: `packages/isa/vaster_instruction`
(encoding) and `packages/runtime/vaster_runtime` (semantics). The golden
vectors in `packages/isa/vaster_conformance/vectors/` are the conformance
anchors: a runtime in any language conforms iff it reproduces every core
vector under the comparison rules in §Conformance procedure. The Dart
reference runner (`ConformanceRunner`) is the executable definition of those
rules._

## Purpose

A `VasterProgram` is a flat, JSON/binary-serializable instruction list — the
compilation target of the declarative AST and the execution unit of every
runtime. This document specifies (1) the abstract machine a conforming
runtime must implement, (2) the wire encoding of every opcode, and (3) the
conformance procedure by which an implementation in any language proves it
executes programs identically. Portability is the claim (rules.md: handles,
descriptors, strings, and JSON only — never host object references); this
spec makes the claim testable.

## Execution model

**The machine.** A conforming runtime holds: a **register file** (string →
JSON value; registers spring into existence on write), a **program counter**
(`pc`, index into the instruction list, initially 0), a **call stack** of
frames `{functionName, returnPc, outputVar?}`, an **error-handler stack**, an
**effect-scope stack**, an active-session/active-model ambient context, a
**quota scope**, and the subsystem state the opcodes below name (sessions,
context regions, mounted filesystems, agents, inboxes, tools).

**Fetch-decode loop.** Execute `instructions[pc]`; unless the instruction
transferred control, `pc` advances by 1. Execution ends when: `halt` retires
(**halted**), a `yield_human_interaction` retires (**pausedForHuman**), or an
error propagates past the last error handler (**error**). Only those three
terminal statuses are legal in conformance vectors.

**Values.** Register values are JSON values (string, number, boolean, null,
array, object). Conformance vectors additionally constrain numbers: integers
within ±2^53; doubles exactly representable (no epsilon comparison exists).

**Interpolation** (normative; reference: `interpolation.dart`). Fields marked
_interp_ in the opcode tables resolve register references before use:

- `$$` → literal `$`.
- `${name}` where `name` matches `[A-Za-z_][A-Za-z0-9_]*` → the register's
  value: strings verbatim; non-strings as canonical JSON (`jsonEncode`);
  present-but-null → empty string.
- Unresolvable references stay verbatim (and surface a runtime warning).
- Identity fields (ids, register names, paths used as identities), tool
  definitions, and schemas never interpolate. Paths interpolate **before**
  policy checks.

**Traps and error handlers.** A failing instruction raises a trap. With a
handler installed (`push_error_handler`), control transfers to its
`targetPc` after writing the error text to the handler's `errorVar` and
unwinding what the failed region abandoned (open transactions above the
handler's mark roll back; effect scopes above it close). With no handler,
the machine ends in **error** status with `pc` at the trapping instruction.
Error message text is implementation prose and is **out of contract**; the
trap's pc is the contract.

**Model turns.** Opcodes that consume a model (`prompt`,
`dispatch_agent_task`, `dispatch_parallel_tasks`, `decide`, and agent-internal
turns) issue a `ModelRequest` and consume a `ModelResponse`. Under
conformance, every response is served from the envelope's **model tape** by
fingerprint-FIFO matching (REPLAY_ENVELOPE.md §Fingerprint) — a conforming
runtime must reproduce the request fingerprints to consume the tape.

## Program header

`VasterProgram.toJson()`:

| field | type | notes |
|---|---|---|
| `programName` | string | default `vaster_program` |
| `resultBinding` | string? | register holding the program's declared result |
| `contextClasses` | object? | opaque context-class table; absent = runtime default |
| `instructions` | array | the instruction list, each per §Opcode reference |

## Register conventions

Sibling registers written next to a declared `outputVar` (one home:
`register_conventions.dart`):

| suffix | written by | value |
|---|---|---|
| `_status` | HITL resume | bool: response was affirmative |
| `_rationale` | `decide` | the model's stated rationale |
| `_outcome` | agent dispatches | outcome kind: `completed`, `model-failure`, `quota-exceeded`, `cancelled`, `refused`, `failure` |

The `__` prefix is reserved (compiler-rejected for user bindings); the
default error register is `__error__`; `__output__` is the legacy result
register superseded by `resultBinding`.

## Opcode reference

The wire field is **`opcode`** (snake_case). Optional operands are
**omitted when null/empty** — absence means the default, never JSON `null`.
_interp_ marks fields resolved per §Interpolation.

### Register file (5)

| opcode | operands | semantics |
|---|---|---|
| `set_register` | `registerName`, `value` (any JSON, may be null) | writes the register |
| `increment_register` | `registerName`, `delta` (num, default 1) | numeric add; non-numeric current value traps |
| `compare_register` | `leftVar`, `operator` (`lt le gt ge eq ne`), `rightVar`? \| `rightValue`?, `targetVar` | writes bool comparison result |
| `json_extract` | `sourceVar`, `jsonKey`, `targetVar` | extracts a key from an object-valued (or JSON-string) register |
| `concat_register` | `targetVar`, `sourceVars` (string list) | concatenates stringified source values in order |

### Control flow (7)

| opcode | operands | semantics |
|---|---|---|
| `jump` | `targetPc` | unconditional transfer |
| `jump_if` | `targetPc`, `conditionVar` | transfer when the register is truthy (`true`) |
| `decide` | `prompt` _interp_, `branches` [{`label`, `description`, `targetPc`}], `outputVar`?, `defaultLabel`? | model-steered multi-way branch: the (taped) response resolves a branch label; writes `outputVar` and its `_rationale` sibling; unresolvable + no default traps |
| `call` | `functionName` (default `anonymous`), `targetPc`, `arguments`? (map: param → source register), `outputVar`? | pushes a call frame (copying argument registers), transfers |
| `return_subroutine` | `returnRegister`? | pops the frame, transfers to `returnPc`; copies the return register into the caller's `outputVar` when both declared |
| `push_error_handler` | `targetPc`, `errorVar` (default `__error__`, always emitted) | installs a handler |
| `pop_error_handler` | — | removes the innermost handler |

### Model / session (6)

| opcode | operands | semantics |
|---|---|---|
| `prompt` | `promptText` _interp_, `outputVar`?, `responseSchema`? | one model turn in the active session; writes the response text |
| `select_model` | `descriptor` (ModelDescriptor), `fallbacks`? (descriptor list) | sets the active model chain (machine state; resolution through the host registry, default model when unregistered) |
| `create_session` | `sessionId`, `modelDescriptor`? | provisions a session |
| `set_session` | `sessionId` | makes it the ambient session |
| `fork_session` | `sourceSessionId`, `targetSessionId` | branches conversation history |
| `check_policy` | `action` (PolicyAction name), `resource` | consults the execution policy; refusal traps |

### VFS / transactions (6)

| opcode | operands | semantics |
|---|---|---|
| `mount_fs` | `mountPrefix` (default `/mem`), `diskPath`? | mounts a filesystem; `diskPath` present = host disk (**capability: host-fs**), absent = in-memory |
| `write_file` | `vfsPath` _interp_, `content` _interp_ | writes text; policy-checked on the resolved path |
| `read_file` | `vfsPath` _interp_, `outputVar`? | reads text into the register; missing file traps |
| `begin_transaction` | — | opens a VFS transaction frame |
| `commit` | — | commits the innermost frame (unpaired commit warns, never traps) |
| `rollback` | — | discards writes since the matching begin |

### Context (6)

| opcode | operands | semantics |
|---|---|---|
| `add_context` | `regionId`, `label`, `text`? _interp_ \| `sourceVar`?, `className`?, `priority`?, `lifetime`?, `compressibility`?, `pinned` | adds/replaces a heap region |
| `pin_context` | `regionId` | pins (survives compaction) |
| `unpin_context` | `regionId` | unpins |
| `evict_context` | `regionId`, `force` | removes a region |
| `set_context_policy` | `regionId`, `priority`?, `pinned`?, `compressibility`?, `utility`? | updates region policy fields |
| `compress_context` | `regionId`?, `targetTokens`?, `outputVar`? | estimator-driven compaction toward the target (default: 90% of the active model's window) |

### Agents / messaging (5)

| opcode | operands | semantics |
|---|---|---|
| `create_agent` | `descriptor` (AgentDescriptor) | provisions an agent and its session (`AgentDescriptor.sessionIdFor` naming) |
| `dispatch_agent_task` | `agentId`, `taskPrompt` _interp_, `outputVar`?, `responseSchema`? | runs one agent task (model turns via tape under conformance); writes the output and its `_outcome` sibling; task ids are pc-derived (`isa_task_<pc>`) |
| `dispatch_parallel_tasks` | `dispatches` [{`agentId`, `taskPrompt` _interp_, `outputVar`?}] | concurrent dispatches; per-entry outputs + `_outcome` siblings; ids `parallel_<pc>_<i>` |
| `send_message` | `senderId`, `recipientId`, `payload` (map; string leaves _interp_) | enqueues an actor message (id `isa_msg_<pc>`) |
| `pop_message` | `agentId`, `outputVar`? | dequeues the oldest unread message into the register (null when empty) |

### Effects / quota / tools (5)

| opcode | operands | semantics |
|---|---|---|
| `push_effect_scope` | — | opens an idempotency scope (machine state) |
| `pop_effect_scope` | — | closes it |
| `mark_effect_retry` | — | marks a retry boundary: recorded effects inside the scope replay instead of re-executing |
| `set_quota` | `quota` (ResourceQuota) | installs the program quota scope; exceeding a budget arm traps (wall-clock arms are **capability: wall-clock**) |
| `register_tool_set` | `tools` (ToolDefinition list) | registers tool schemas for subsequent model turns |

### Sandbox (2) — capability: sandbox

| opcode | operands | semantics |
|---|---|---|
| `register_sandbox` | `sandboxId`, `language` (default `dart`), `timeoutMs`? | binds a live execution backend |
| `exec_sandbox` | `sandboxId`, `code` _interp_, `outputVar`? | executes code; output is host-produced and not taped |

### HITL (1) + halt (1)

| opcode | operands | semantics |
|---|---|---|
| `yield_human_interaction` | `request` {`requestId`, `type`, `prompt` _interp_, `options`?, `outputVar`?, `timeoutMs`?} | pauses the machine (**pausedForHuman**) with the pending request; resume (out of conformance scope) writes `outputVar` + `_status` |
| `halt` | — | ends execution (**halted**) |

## Conformance classes

**core** — everything above not marked as a capability: 42 opcodes, all
exercised by the golden vectors. **capability** — host-dependent behavior a
vector cannot pin: `register_sandbox`/`exec_sandbox` (live execution),
`mount_fs` with `diskPath` (real disk), HITL *resume* (the response is not
part of the envelope; the pause state IS core), wall-clock quota/deadline
arms, and live (non-tape) model backends. Conformance runs register no live
backends: every model resolution falls through to the tape.

## Conformance procedure

A vector is `<name>.vector.json` (manifest) + sibling `<name>.replay.json`
(replay envelope v2, REPLAY_ENVELOPE.md). Manifest shape:

```jsonc
{ "conformanceVersion": 1,
  "name": "core.vfs.transactions",
  "description": "…",
  "class": "core",                    // or "capability" (+ "capability": "…")
  "family": "vfs",
  "envelope": "core.vfs.transactions.replay.json",
  "expect": {
    "finalStatus": "halted",          // halted | pausedForHuman | error
    "steps": 10,                      // == journal frame count (truncation guard)
    "result": {"value": "base"},      // ? value of resultBinding at halt
    "trapPc": 1,                      // ? required for error status
    "pendingRequest": {"requestId": "gate", "prompt": "…", "type": "approval"},  // ? subset-matched
    "vfs": {"/data": {"/data/base.txt": "<base64>"}}  // ? memory-mount exports
  } }
```

**Execution**: load the embedded program, run it with every model resolution
answered from the envelope's tape (fingerprint-FIFO), unlimited budget/policy,
no live backends, no real filesystem.

**Comparison rules (normative)** — for each journal frame `N`, in order:

1. **pc, before executing step N**: the machine's pc MUST equal
   `frames[N].pc`. Jumps, calls, and decide landings are thereby verified by
   the successor frame — there are no control-flow special cases.
2. **instruction**: the program is normative; cross-check only
   `frames[N].instruction.opcode == program.instructions[pc].opcode`
   (mispair detection). Frames record the STATIC instruction —
   interpolation is never visible in the journal.
3. **registers, after executing step N**: deep JSON equality with exact key
   sets (a `null` value is distinct from an absent key), key-order-insensitive
   objects, order-sensitive arrays, exact strings/bools, and **mathematical
   number equality** (`1` == `1.0`). Dart-`toString` coercion is NOT this
   rule.
4. **callStack**: ordered outermost-first, `{functionName, returnPc,
   outputVar?}` per frame; an omitted field means an empty stack.
5. **timestamp**: excluded — it is the journal's only nondeterministic
   field (golden vectors carry the epoch sentinel `1970-01-01T00:00:00.000Z`).
   `modelOutput` is reserved: ignore it.

After all frames: `finalStatus`; `result` under rule 3; for `error`, `trapPc`
only (message prose is out of contract); for `pausedForHuman`, subset-match
`pendingRequest`; `vfs` exports by exact base64 equality; total steps MUST
equal `expect.steps`.

**Divergence reporting**: stop at the FIRST mismatch; report `{vectorName,
stepIndex, fieldPath, expected, actual}` with JSON-pointer-style paths
(`registers.items[2].name`). Length mismatches report at
`min(executedSteps, frames.length)` with path `length`; final-state
mismatches report at `frames.length`. Tape divergence reports per
REPLAY_ENVELOPE.md §Divergence.

## VBC binary format (version 2)

Reference codec: `vbc_codec.dart`. Layout:

```
magic     u32 BE = 0x56424301
version   u16 BE = 2  (minSupported = 1)
flags     u16 BE = 0  (reserved)
sha256    32 bytes over payload
payload:
  poolCount        varint            # string pool
  pool[i]          varint len + utf8
  programNameIdx   varint
  header           tagged value      # v2: {contextClasses?, resultBinding?} or null tag
  instrCount       varint
  instr[i]         tagged value      # the instruction's JSON map
```

Tags: `0x00` null · `0x01` false · `0x02` true · `0x03` int (zigzag varint) ·
`0x04` double (float64 BE) · `0x05` string (pool index) · `0x06` list ·
`0x07` map (keys are pool indices). Varints are LEB128. Int vs double is
preserved exactly (JSON text is not authoritative for numeric type). Decode
errors are typed (`VbcDecodeException`): bad magic, unsupported version,
checksum mismatch, truncation, unknown tag, pool overrun; an unknown opcode
is a `FormatException` naming it.

## Versioning & migration

- This document: additive-monotonic; a new opcode or field bumps the doc's
  version and MUST land with (a) its ISA.md entry (coverage-gated: the suite
  fails if a registered opcode is undocumented) and (b) a core vector or a
  documented capability classification (coverage-gated likewise).
- Vectors: `conformanceVersion` follows the envelope discipline — readers
  refuse newer versions, never partially read.
- VBC and the envelope carry their own version words (above;
  REPLAY_ENVELOPE.md §Migration guarantees). The 1.0 promise: a program or
  recording produced on 1.x loads on any 1.y ≥ x via versioned migration,
  never silent rejection.
- **Backward-decode anchors** — golden bytes produced by the REAL
  historical encoders, committed in
  `packages/isa/vaster_instruction/test/fixtures/`: `v1_program.vbc`
  (formatVersion 1, no header section) and `v2_legacy_classes.vbc` (early
  v2 whose header value was the class-table map). A conforming decoder
  MUST parse those exact bytes and produce the committed
  `.expected.json` programs; re-encoding at the current version MUST
  round-trip identically. This is the migration promise, executed.
