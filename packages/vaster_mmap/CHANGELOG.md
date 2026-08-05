# Changelog

## Unreleased

- **Composition over parallel monoliths** across the whole package:
  - `ShmSegment.attach` — attach-only opening (throws when the segment does
    not exist, never creates); both the ring's and the frame's attach paths
    now probe through it instead of the old create-then-detect hack. One
    internal open ladder serves create-or-attach and attach-only alike.
  - `ShmSegment.view(offset, length)` — the one place a protocol gets its
    typed slice of the mapping.
  - New `SegmentTag` composable owns segment identity (magic + version as
    the first two header words) for every protocol; the ring and the frame
    stamp/validate through it instead of hand-rolling header checks.
  - **`SharedMemoryFrame` rebuilt as a thin composition** over
    `ShmSegment` + `SegmentTag` — its private copy of the shm/fallback/mmap
    ladder is gone. `FrameHeader` is v2 (versioned, tag-first).
  - **BREAKING (behavior)**: `SharedMemoryFrame.create` on an existing name
    is now content-addressed idempotent — it validates and attaches to the
    existing frame instead of silently overwriting pages a peer may be
    reading; a payload-length mismatch throws. Frames keep their
    content-at-rest lifetime: `close()` detaches by default for creator and
    attacher alike.

- **`SharedMemoryRing` rebuilt in layers** (roadmap item 8):
  - `ShmSegment` — mapping lifecycle only: explicit owner-vs-attacher via
    `O_EXCL`, descriptors closed immediately after `mmap` (the old code had
    no `close` binding at all — every ring leaked its fd), all-final fields,
    failure paths clean up exactly what they opened. File fallback keeps the
    same ownership semantics and grows undersized stale backings instead of
    faulting.
  - `RingBuffer` — the pure SPSC protocol core: length-prefixed frames,
    two-segment `setRange` copies (the old "zero-copy" path copied one byte
    per loop iteration), **real backpressure** (`tryWrite`/`RingFullException`
    — the old ring let the head lap unread data and silently corrupt frames),
    and `RingCorruptionException` guards on indices and prefixes. Unit-tested
    with zero FFI.
  - `SharedMemoryRing` — thin composition keeping the old public surface
    (`writePacket`/`readPacket`/`writeString`/`readString`/`close`) plus
    `tryWritePacket`/`tryWriteString`, `freeBytes`, `isOwner`, and a
    capacity-discovering `SharedMemoryRing.attach(name)`.
- **BREAKING**: `close()` unlinks only when this instance created the segment
  (or with `close(unlink: true)`) — an attacher's close no longer destroys
  the ring its peer is still using. Header layout is v2 (versioned,
  little-endian prefixes, dead `status` word removed); attach validates
  magic/version/capacity against the header page before touching payload.
- POSIX open flags are resolved per platform (`O_CREAT`/`O_EXCL` differ
  between Darwin and Linux; the old constants were Darwin-only).
- `SharedMemoryFrame` no longer leaks its descriptor after mapping.

## 0.2.0

- Zero-copy POSIX shared-memory IPC transport: `SharedMemoryRing`,
  `SharedMemoryFrame`, `MmapVasterModel`, KV frame refs.
