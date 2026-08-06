import 'dart:ffi';
import 'dart:typed_data';

import 'segment_tag.dart';
import 'shm_segment.dart';

/// Layout of a shared-memory frame header. Begins with the shared
/// [SegmentTag] words (magic, version) like every Vaster segment protocol.
base class FrameHeader extends Struct {
  @Uint32()
  external int magic; // 0x564B5646 ("VKVF")

  @Uint32()
  external int version; // layout version — see [frameVersion]

  @Uint32()
  external int payloadLength;

  @Uint32()
  external int meta; // caller-defined (e.g. token count of a KV frame)
}

const int frameMagic = 0x564B5646; // "VKVF" — Vaster KV Frame

/// Header layout version. v2: versioned header sharing the [SegmentTag]
/// convention with the ring.
const int frameVersion = 2;

/// The frame's segment identity, composed from the shared [SegmentTag]
/// convention.
const SegmentTag frameTag =
    SegmentTag(magic: frameMagic, version: frameVersion, protocol: 'frame');

/// A named POSIX shared-memory **blob segment** holding a single immutable
/// payload — the physical-frame primitive underneath zero-copy KV state
/// sharing.
///
/// Unlike [SharedMemoryRing] (a message-passing ring), a frame is
/// content-at-rest: one process [create]s it, any process that knows the
/// name can [attach] and read the payload through a zero-copy [bytes] view
/// over the same physical pages.
///
/// Like the ring, the frame is a thin protocol *composed* over the two
/// shared building blocks — [ShmSegment] owns the mapping lifecycle,
/// [SegmentTag] owns segment identity — instead of carrying its own copy of
/// the open/attach/mmap ladder.
///
/// ### Content-addressed idempotency
/// Frame names derive from content fingerprints, so [create] on a name that
/// already exists is a benign race with a peer materializing the *same*
/// content: create validates the existing frame and returns it as an
/// attachment instead of rewriting live pages under the peer (the old
/// implementation silently overwrote). A payload-length mismatch means the
/// name does NOT address the same content — that throws.
///
/// ### Lifetime
/// Frames outlive handles: [close] detaches by default (`unlink: false`) for
/// creator and attacher alike — state stays discoverable cross-process until
/// someone closes with `unlink: true` (eviction).
final class SharedMemoryFrame {
  final ShmSegment _segment;
  final int payloadLength;

  /// Caller-defined metadata word stored in the header.
  final int meta;

  SharedMemoryFrame._(this._segment, this.payloadLength, this.meta);

  String get name => _segment.name;

  /// True when this instance materialized the frame (vs attached to one a
  /// peer had already materialized).
  bool get isOwner => _segment.isOwner;

  static int get _headerSize => sizeOf<FrameHeader>();

  /// Creates the named frame with [payload], or — when a peer already
  /// materialized it — validates and attaches to the existing frame
  /// (see *Content-addressed idempotency* above).
  factory SharedMemoryFrame.create(String name, Uint8List payload,
      {int meta = 0}) {
    final segment =
        ShmSegment.open(name: name, size: _headerSize + payload.length);
    final header = segment.base.cast<FrameHeader>();

    if (segment.isOwner) {
      frameTag.stamp(segment);
      header.ref
        ..payloadLength = payload.length
        ..meta = meta;
      segment.view(_headerSize, payload.length).setAll(0, payload);
      return SharedMemoryFrame._(segment, payload.length, meta);
    }

    // Existing frame: same name must mean same content. Validate the tag
    // against the header page before trusting any field, then insist the
    // lengths agree — never rewrite pages a peer may be reading.
    frameTag.validate(segment);
    final existingLength = header.ref.payloadLength;
    if (existingLength != payload.length) {
      segment.close(unlink: false);
      throw StateError(
          'Frame "$name" already exists with a $existingLength-byte payload; '
          'refusing to overwrite it with ${payload.length} bytes — '
          'content-addressed names must not collide.');
    }
    return SharedMemoryFrame._(segment, existingLength, header.ref.meta);
  }

  /// Creates the named frame sized for a [payloadLength]-byte payload the
  /// caller will fill *after* creation — through [payloadPointer] (native
  /// writers like `llama_state_seq_get_data`) or [bytes]. When a peer
  /// already materialized the name, validates and attaches exactly like
  /// [create]; check [isOwner] to know whether filling is yours to do.
  ///
  /// Single-writer discipline: the frame is publishable to peers only once
  /// the owner's fill completes — same content-at-rest contract as [create],
  /// which fills before returning.
  factory SharedMemoryFrame.allocate(String name,
      {required int payloadLength, int meta = 0}) {
    final segment =
        ShmSegment.open(name: name, size: _headerSize + payloadLength);
    final header = segment.base.cast<FrameHeader>();

    if (segment.isOwner) {
      frameTag.stamp(segment);
      header.ref
        ..payloadLength = payloadLength
        ..meta = meta;
      return SharedMemoryFrame._(segment, payloadLength, meta);
    }

    frameTag.validate(segment);
    final existingLength = header.ref.payloadLength;
    if (existingLength != payloadLength) {
      segment.close(unlink: false);
      throw StateError(
          'Frame "$name" already exists with a $existingLength-byte payload; '
          'refusing a $payloadLength-byte allocation — '
          'content-addressed names must not collide.');
    }
    return SharedMemoryFrame._(segment, existingLength, header.ref.meta);
  }

  /// Attaches to an existing named frame. Probes the header first (touching
  /// only the segment's first page), learns the payload length, then maps in
  /// full. Throws [StateError] when the frame does not exist or the segment
  /// is not a valid frame — attach never creates anything.
  factory SharedMemoryFrame.attach(String name) {
    final probe = ShmSegment.attach(name: name, size: _headerSize);
    final int payloadLength;
    final int meta;
    try {
      frameTag.validate(probe);
      final header = probe.base.cast<FrameHeader>().ref;
      payloadLength = header.payloadLength;
      meta = header.meta;
    } finally {
      probe.close(unlink: false);
    }

    final segment =
        ShmSegment.attach(name: name, size: _headerSize + payloadLength);
    return SharedMemoryFrame._(segment, payloadLength, meta);
  }

  /// Zero-copy view of the payload — backed directly by the shared pages.
  Uint8List get bytes => _segment.view(_headerSize, payloadLength);

  /// Native address of the payload region — for FFI writers/readers that
  /// move state directly between an inference engine and the shared pages
  /// (e.g. `llama_state_seq_get_data`/`set_data`) without staging through
  /// the Dart heap. Valid for [payloadLength] bytes until [close].
  Pointer<Uint8> get payloadPointer =>
      Pointer<Uint8>.fromAddress(_segment.base.address + _headerSize);

  /// Detaches from the frame; with [unlink] the underlying segment is
  /// destroyed (eviction). Detach is the default for creator and attacher
  /// alike — frames are content-at-rest and outlive handles. Idempotent.
  void close({bool unlink = false}) => _segment.close(unlink: unlink);
}
