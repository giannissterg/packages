import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'ring_buffer.dart';
import 'segment_tag.dart';
import 'shm_segment.dart';

/// Layout of the shared ring header at the base of the segment.
///
/// `head`/`tail` are aligned 32-bit words — aligned word stores are
/// single-copy-atomic on x86-64 and ARM64, which is what the SPSC publication
/// discipline in [RingBuffer] relies on. (The old header carried a `status`
/// word that nothing ever read; it is gone.)
base class ShmRingHeader extends Struct {
  @Uint32()
  external int magic; // 0x56415354 ("VAST")

  @Uint32()
  external int version; // layout version — see [shmRingVersion]

  @Uint32()
  external int capacity; // payload region size in bytes

  @Uint32()
  external int head; // producer cursor

  @Uint32()
  external int tail; // consumer cursor
}

const int shmMagic = 0x56415354; // "VAST"

/// Header layout version. v2: versioned header, little-endian frame
/// prefixes, no dead status word.
const int shmRingVersion = 2;

/// The ring's segment identity, composed from the shared [SegmentTag]
/// convention (magic + version as the first two header words).
const SegmentTag ringTag = SegmentTag(magic: shmMagic, version: shmRingVersion, protocol: 'ring');

const int defaultShmCapacity = 4 * 1024 * 1024; // 4MB payload region

/// [RingIndices] backed by the shared header words.
final class _ShmRingIndices implements RingIndices {
  final Pointer<ShmRingHeader> _header;

  _ShmRingIndices(this._header);

  @override
  int get head => _header.ref.head;
  @override
  set head(int value) => _header.ref.head = value;

  @override
  int get tail => _header.ref.tail;
  @override
  set tail(int value) => _header.ref.tail = value;
}

/// Single-producer / single-consumer frame ring over POSIX shared memory.
///
/// A thin composition of the two real layers:
/// - [ShmSegment] owns the mapping lifecycle (create-vs-attach, fd hygiene,
///   unlink-on-close only for the owner);
/// - [RingBuffer] owns every byte of protocol (framing, backpressure,
///   two-segment copies, corruption guards) and is fully unit-tested with no
///   FFI in sight.
///
/// ### Concurrency contract
/// One producer process/isolate writes, one consumer reads (see
/// [RingBuffer]'s SPSC contract). For duplex traffic use two rings, one per
/// direction — sharing one ring both ways is what the old half-duplex mode
/// did and it forces consumers to skip their own frames.
///
/// ### Backpressure
/// [writePacket] throws [RingFullException] when the consumer is not
/// draining; [tryWritePacket] returns false instead. The ring never
/// overwrites unread frames.
class SharedMemoryRing {
  final ShmSegment _segment;
  final RingBuffer _ring;

  /// Payload capacity in bytes.
  final int capacity;

  bool _closed = false;

  SharedMemoryRing._(this._segment, this._ring, this.capacity);

  String get shmName => _segment.name;

  /// True when this instance created the segment; the owner unlinks it on
  /// [close], attachers merely detach.
  bool get isOwner => _segment.isOwner;

  bool get isEmpty => _ring.isEmpty;

  /// Bytes available to the producer right now.
  int get freeBytes => _ring.freeBytes;

  /// Largest single payload this ring can ever carry.
  int get maxFrameLength => _ring.maxFrameLength;

  static int get _headerSize => sizeOf<ShmRingHeader>();

  /// Opens the named ring, creating it when absent (create-or-attach).
  ///
  /// The creator initializes the header; an attacher validates magic,
  /// version, and that [capacity] matches what the creator declared —
  /// validation happens against the header page only, *before* any payload
  /// byte is touched, so a mismatched attach throws instead of faulting.
  factory SharedMemoryRing({
    required String shmName,
    int capacity = defaultShmCapacity,
  }) {
    if (capacity < RingBuffer.minCapacity) {
      throw ArgumentError.value(capacity, 'capacity', 'must be >= ${RingBuffer.minCapacity} bytes');
    }

    final segment = ShmSegment.open(name: shmName, size: _headerSize + capacity);
    final header = segment.base.cast<ShmRingHeader>();

    if (segment.isOwner) {
      ringTag.stamp(segment);
      header.ref
        ..capacity = capacity
        ..head = 0
        ..tail = 0;
    } else {
      ringTag.validate(segment);
      if (header.ref.capacity != capacity) {
        final found = header.ref.capacity;
        segment.close(unlink: false);
        throw StateError('Segment "$shmName" was created with capacity $found, not '
            "$capacity — attach with the creator's capacity.");
      }
    }

    return SharedMemoryRing._(segment, _ringOver(segment, capacity), capacity);
  }

  /// Attaches to an existing ring without knowing its capacity.
  ///
  /// Probes the header first (a header-sized mapping touches only the
  /// segment's first page, which every live segment backs), reads the
  /// creator's capacity, then maps in full. Throws [StateError] when the
  /// ring does not exist — attach never creates anything.
  factory SharedMemoryRing.attach(String shmName) {
    final probe = ShmSegment.attach(name: shmName, size: _headerSize);
    final int capacity;
    try {
      ringTag.validate(probe);
      capacity = probe.base.cast<ShmRingHeader>().ref.capacity;
    } finally {
      probe.close(unlink: false);
    }

    final segment = ShmSegment.attach(name: shmName, size: _headerSize + capacity);
    return SharedMemoryRing._(segment, _ringOver(segment, capacity), capacity);
  }

  static RingBuffer _ringOver(ShmSegment segment, int capacity) => RingBuffer(
        data: segment.view(_headerSize, capacity),
        indices: _ShmRingIndices(segment.base.cast<ShmRingHeader>()),
      );

  /// Writes one binary frame; throws [RingFullException] when it does not
  /// fit (the consumer is not draining).
  void writePacket(List<int> bytes) {
    _checkOpen();
    _ring.write(bytes);
  }

  /// Writes one binary frame if it fits; returns false otherwise.
  bool tryWritePacket(List<int> bytes) {
    _checkOpen();
    return _ring.tryWrite(bytes);
  }

  /// Reads the next binary frame, or null when the ring is empty.
  Uint8List? readPacket() {
    _checkOpen();
    return _ring.read();
  }

  /// A ring op after [close] would touch unmapped pages — a native fault.
  /// Surface it as a typed error instead (a poll loop outliving its ring
  /// is a bug the caller must see, not a SIGSEGV).
  void _checkOpen() {
    if (_closed) {
      throw StateError('SharedMemoryRing "$shmName" is closed.');
    }
  }

  /// Writes a UTF-8 string frame (same backpressure as [writePacket]).
  void writeString(String text) => writePacket(utf8.encode(text));

  /// Writes a UTF-8 string frame if it fits; returns false otherwise.
  bool tryWriteString(String text) => tryWritePacket(utf8.encode(text));

  /// Reads the next frame as a UTF-8 string, or null when empty.
  String? readString() {
    final bytes = readPacket();
    return bytes == null ? null : utf8.decode(bytes);
  }

  /// Unmaps the ring. The segment is destroyed when [unlink] is true,
  /// defaulting to [isOwner] — an attacher's close no longer tears down the
  /// ring its peer is still using. Idempotent.
  void close({bool? unlink}) {
    _closed = true;
    _segment.close(unlink: unlink);
  }
}
