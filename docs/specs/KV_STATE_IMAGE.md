# KV State Image — format specification, version 1

_Status: normative. The reference codec is `KvStateImageCodec` (yielding parsed `KvStateImage` values) in
`vaster_kv` (the KV contracts leaf — the format is container-agnostic,
so it lives with the contracts, not with any transport); the
golden-bytes fixture in
`packages/vaster_kv/test/kv_state_image_test.dart` is the conformance
anchor — an implementation in any language must produce and parse those
exact bytes._

## Purpose

A **KV state image** is the payload of a materialized KV frame: an
inference engine's exported sequence state, together with the provenance
required to reuse it safely — the exact token ids that were decoded into
the state, the identity of the producer, and the source-content
fingerprint. It is a self-describing, versioned, language-agnostic
binary format: a consumer written in any language can validate and reuse
(or refuse) an image without consulting the producer.

The image is *container-agnostic*. In Vaster it lives in a
`SharedMemoryFrame` payload (the frame's own header — magic `VKVF`,
version, length, meta — is the container layer and is not part of this
format), but the same bytes are meaningful in a file or any other
transport.

## Layout

All multi-byte integers are **little-endian**. All offsets are from the
start of the image. Sections appear in this order, with zero-filled
padding between them as specified.

| offset | size | field | notes |
|---|---|---|---|
| 0 | 4 | `magic` | u32, `0x564B5649` ("VKVI") |
| 4 | 4 | `version` | u32, `1` |
| 8 | 4 | `flags` | u32, reserved — MUST be `0` in v1 |
| 12 | 4 | `tokenCount` | u32, `n` |
| 16 | 8 | `engineTag` | u64, opaque producer identity (see below) |
| 24 | 8 | `stateSize` | u64, `s` |
| 32 | 4 | `fingerprintLength` | u32, `f` (bytes) |
| 36 | `f` | `contentFingerprint` | UTF-8, no terminator |
| 36+f | pad | zero bytes to the next 4-byte boundary | |
| `tok` | 4·n | `tokenIds` | i32 each — the decoded prefix, in decode order |
| tok+4n | pad | zero bytes to the next 8-byte boundary | |
| `st` | `s` | `state` | opaque engine state (e.g. `llama_state_seq_get_data` output) |

`tok = align4(36 + f)`, `st = align8(tok + 4·n)`, total image length
`= st + s`.

**Container requirements**: the container MUST present the image at an
8-byte-aligned base address (both the token and state sections rely on
it; `SharedMemoryFrame` payloads satisfy this — page-aligned mapping +
16-byte frame header). The container's payload MUST be at least the
image length; consumers MUST ignore any trailing container bytes.

## Producing

1. Compute the total length from `n`, `f`, `s`; obtain a buffer of at
   least that size at an 8-aligned base.
2. Write the header, fingerprint, and token ids; zero-fill both padding
   runs.
3. Fill the state section last (in Vaster: the engine writes it in place
   — `payloadPointer + st` — so state never stages through a heap).
4. Publish only after the image is complete (single-writer discipline;
   in Vaster, materialization is atomic at the worker mailbox).

## Consuming — normative reuse semantics

A consumer MUST, in order, before touching the state section:

1. Verify `magic`, `version` (reject unknown), and `flags == 0`
   (v1 readers reject flags they do not understand).
2. Verify the buffer covers the declared length (truncation check using
   `tokenCount`, `fingerprintLength`, `stateSize`).
3. Verify both padding runs are zero (cheap corruption/foreign-writer
   detection).
4. Compare `engineTag` for equality with its own tag. A mismatch means
   the state was produced by a different engine build or model — the
   consumer MUST NOT restore it, regardless of token agreement (a
   different model with an agreeing tokenizer would restore garbage
   state).
5. **Token-exact prefix validation**: tokenize the target prompt and
   verify its first `n` token ids equal `tokenIds` exactly. On any
   divergence — including the prompt being shorter than `n` — the
   consumer MUST NOT reuse the state and MUST fall back to a cold
   decode. Reuse is only ever an optimization; a wrong-context
   completion is a correctness failure.

Only after 1–5 may the state section be handed to the engine
(`llama_state_seq_set_data` or equivalent). The engine's own internal
state versioning remains the final authority; its rejection is surfaced
as a typed error, never a silent cold start.

## `engineTag`

An opaque 64-bit value compared only for equality. Producers derive it
from everything that affects state compatibility — at minimum the engine
implementation/build and the model identity. The reference
implementation uses FNV-1a 64 over a producer-composed description
string (see `KvStateImage.engineTagOf`). Consumers MUST NOT parse it.

## Endianness note

The format is little-endian by definition. The reference codec reads
token ids through a zero-copy host-endian `Int32List` view, which is
correct on all currently supported platforms (arm64, x86-64); a
big-endian implementation must byte-swap and forfeits that particular
zero-copy path — the format itself does not change.

## Versioning

`version` increments on any layout change; v1 consumers reject other
versions. `flags` is the forward-compatibility escape hatch for
non-layout semantics (v1 writers write 0, v1 readers reject non-zero) —
a future flag bit, once assigned, will come with a version-1-compatible
reading discipline or a version bump, whichever the change demands.
