# Replay Envelope & Model Tape — format specification, version 2

_Status: normative. Reference implementation: `ReplayEnvelopeCodec` and
the tape values in `vaster_replay` (bridges). The committed fixtures are
the conformance anchors: `sdd_fidelity.replay.json` (v1, recorded on a
paid run — **irreplaceable, and therefore the standing migration
test**: it must replay correctly forever) and the llama-recorded v2
fixture beside it._

## Purpose

A **replay envelope** is a complete, deterministic re-execution recipe
for one pipeline run: the compiled program, the step journal, and the
**model tape** — every model request/response pair, fingerprinted. It
serves three consumers: deterministic replay (`vaster run --replay`,
zero tokens), time-travel debugging (`vaster debug`), and — from v2 —
**divergence diffing** (`vaster replay --diff`) and estimate
calibration, both of which need the full recorded requests that v1
omitted.

## Envelope layout (JSON object)

| field | v1 | v2 | notes |
|---|---|---|---|
| `version` | absent | `2` | absent MUST be read as 1 |
| `program` | optional | required | `VasterProgram.toJson()` — makes the envelope self-contained |
| `journal` | required | required | the step journal (schema owned by `ExecutionStepFrame`; versioned with the envelope) |
| `modelTape` | required | required | see below |

## Model tape layout

```json
{ "version": 2,                      // absent = 1
  "recordedModelName": "...",        // optional
  "recordedCapabilities": {...},     // optional; replay MUST present these
  "entries": [ <entry>... ] }
```

Capabilities are recorded because they shape the requests themselves
(context compilation sizes from them); a faithful replay presents what
was recorded.

### Tape entry

| field | v1 | v2 | notes |
|---|---|---|---|
| `fingerprint` | required | required | see §Fingerprint |
| `requestPreview` | required | required | human-readable excerpt (≤120 chars); kept in v2 for logs |
| `request` | **absent** | required | full `ModelRequest.toJson()` — messages, system instruction, tools, generation config, cache hints |
| `response` | required | required | full `ModelResponse.toJson()` incl. measured usage |

**Reader rule (normative):** an entry with a `request` field is a *full*
recording; without one it is *preview-only*. Readers MUST accept both in
any tape. Features requiring full requests (message-level diffing,
prompt-side calibration) MUST degrade explicitly on preview-only entries
— name the limitation, never guess.

**Streams are not recorded.** The ISA runtime's execution path is
`generate`; `generateStream` delegates unrecorded. A future streaming
runtime path versions the tape again rather than bending this rule
silently.

## Fingerprint — a cross-version contract

Matching is by fingerprint with FIFO order among identical fingerprints
(robust to parallel-dispatch arrival order). **v1 and v2 MUST fingerprint
identically**, or v2 readers would mismatch v1 tapes. The algorithm is
therefore part of this spec:

1. Canonical content: the JSON object
   `{"messages":[{"role":<role name>,"text":<message text>}...],
   "tools":[<tool name>...],"schema":<responseSchema or null>}`
   serialized with Dart's `jsonEncode` field order as written.
   Deliberately excluded: usage, cache hints, generation parameters
   other than the schema — equivalent requests must match across runs.
2. Hash: FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime
   `0x100000001b3`) over the UTF-16 code units of the canonical string,
   wrapping in signed 64-bit arithmetic.
3. Rendering: mask to 63 bits (`& 0x7FFFFFFFFFFFFFFF`), lowercase hex,
   left-padded to 16 characters.

## Divergence (v2 semantics)

A replayed run whose request has no unconsumed fingerprint match has
**diverged** — that is the regression signal, and it is typed data, not
a message string: implementations surface the live request, the call
index, and the unconsumed candidates (`TapeDivergenceException` in the
reference). Diff reporting aligns the Nth live call with the Nth
recording (positional — the story a regression report tells), while
fingerprint-FIFO remains the *matching* rule.

## Migration guarantees (the 1.0 gate-1 discipline)

- v1 envelopes and tapes remain readable by every future reader. The
  paid v1 fixture is the permanent regression test of this promise.
- Writers always write the current version.
- `version` is additive-monotonic; readers reject versions they do not
  know (no silent partial reads).

## Size

Full requests make v2 tapes larger — deliberately: the request content
IS the value (diffing, calibration, re-recording). Producers recording
context-heavy runs should expect tape size on the order of total prompt
chars. There is no "lite" mode; one format, one story.
