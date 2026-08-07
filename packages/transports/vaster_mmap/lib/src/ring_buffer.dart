import 'dart:math' as math;
import 'dart:typed_data';

/// Where a ring's head/tail indices live.
///
/// The ring's index words are storage-owned (in a shared-memory header for
/// IPC, in plain fields for tests) — abstracting them is what makes
/// [RingBuffer] pure: all index arithmetic and copy logic is testable with
/// zero FFI.
abstract interface class RingIndices {
  /// Producer cursor: offset of the next byte to write.
  int get head;
  set head(int value);

  /// Consumer cursor: offset of the next byte to read.
  int get tail;
  set tail(int value);
}

/// In-memory indices for tests and single-process rings.
final class MemoryRingIndices implements RingIndices {
  @override
  int head = 0;
  @override
  int tail = 0;
}

/// A frame does not fit in the ring's current free space.
///
/// This is backpressure, not corruption — the caller decides whether to wait
/// for the consumer to drain, drop, or fail. (The previous implementation had
/// no such check: the head lapped unread data and silently corrupted frames.)
final class RingFullException implements Exception {
  final int frameLength;
  final int freeBytes;

  const RingFullException({required this.frameLength, required this.freeBytes});

  @override
  String toString() => 'RingFullException: frame of $frameLength bytes needs '
      '${frameLength + RingBuffer.framePrefixBytes} bytes but only '
      '$freeBytes are free (consumer not draining?)';
}

/// The ring's stored indices or frame prefix are inconsistent.
///
/// Reaching this means a peer violated the single-producer/single-consumer
/// discipline or the segment was corrupted externally — the ring cannot
/// recover and should be closed.
final class RingCorruptionException implements Exception {
  final String message;

  const RingCorruptionException(this.message);

  @override
  String toString() => 'RingCorruptionException: $message';
}

/// Pure single-producer / single-consumer frame ring over a byte region.
///
/// Frames are length-prefixed (4-byte little-endian) and copied in at most
/// two [Uint8List.setRange] segments (pre-wrap + post-wrap) — no
/// byte-at-a-time loops. One byte of capacity is reserved so a full ring is
/// distinguishable from an empty one (`head == tail` always means empty).
///
/// ### Concurrency contract (SPSC)
/// Exactly one producer calls [tryWrite]/[write]; exactly one consumer calls
/// [read]. The producer publishes a frame by advancing `head` only *after*
/// the payload bytes are written; the consumer releases space by advancing
/// `tail` only *after* copying the payload out. Index words must be aligned
/// 32-bit slots (aligned word stores are single-copy-atomic on x86-64 and
/// ARM64). Dart exposes no cross-process memory fences, so this is a
/// polling-friendly SPSC ring, not a general MPMC queue — honest about what
/// the platform gives us. Multiple producers or consumers on the same ring
/// are undefined behavior.
final class RingBuffer {
  /// Bytes of length prefix ahead of every frame payload.
  static const int framePrefixBytes = 4;

  /// Smallest capacity that can carry a non-trivial frame.
  static const int minCapacity = 16;

  final Uint8List _data;
  final RingIndices _indices;

  RingBuffer({required Uint8List data, required RingIndices indices})
      : _data = data,
        _indices = indices {
    if (data.length < minCapacity) {
      throw ArgumentError.value(data.length, 'data', 'ring capacity must be >= $minCapacity bytes');
    }
  }

  int get capacity => _data.length;

  /// Bytes currently occupied by unread frames (prefixes included).
  int get usedBytes {
    _checkIndex(_indices.head, 'head');
    _checkIndex(_indices.tail, 'tail');
    // Dart's % is Euclidean: non-negative for a positive modulus.
    return (_indices.head - _indices.tail) % capacity;
  }

  /// Bytes available to the producer. One byte is permanently reserved so
  /// `head == tail` is unambiguous (empty), never "completely full".
  int get freeBytes => capacity - 1 - usedBytes;

  bool get isEmpty => _indices.head == _indices.tail;

  /// Largest payload that could ever fit in this ring in one frame.
  int get maxFrameLength => capacity - 1 - framePrefixBytes;

  /// Writes one frame if it fits; returns false (writing nothing) when it
  /// does not — typed backpressure instead of silent overwrite.
  bool tryWrite(List<int> frame) {
    final total = framePrefixBytes + frame.length;
    if (total > freeBytes) return false;

    final head = _indices.head;
    final prefix = ByteData(framePrefixBytes)..setUint32(0, frame.length, Endian.little);
    _copyIn(head, prefix.buffer.asUint8List());
    _copyIn((head + framePrefixBytes) % capacity, frame);
    // Publish AFTER the payload bytes exist — the consumer never observes a
    // head that points past unwritten data.
    _indices.head = (head + total) % capacity;
    return true;
  }

  /// Writes one frame or throws [RingFullException].
  void write(List<int> frame) {
    if (!tryWrite(frame)) {
      throw RingFullException(frameLength: frame.length, freeBytes: freeBytes);
    }
  }

  /// Reads the next frame, or null when the ring is empty.
  Uint8List? read() {
    if (isEmpty) return null;

    final used = usedBytes;
    if (used < framePrefixBytes) {
      throw const RingCorruptionException('ring holds fewer bytes than a frame prefix');
    }

    final tail = _indices.tail;
    final prefix = _copyOut(tail, framePrefixBytes);
    final length = ByteData.sublistView(prefix).getUint32(0, Endian.little);
    if (length > used - framePrefixBytes) {
      throw RingCorruptionException('frame prefix claims $length bytes but only '
          '${used - framePrefixBytes} are in the ring');
    }

    final payload = _copyOut((tail + framePrefixBytes) % capacity, length);
    // Release AFTER the copy-out — the producer never reclaims bytes the
    // consumer is still reading.
    _indices.tail = (tail + framePrefixBytes + length) % capacity;
    return payload;
  }

  /// Copies [src] into the ring at [pos] in at most two contiguous segments.
  void _copyIn(int pos, List<int> src) {
    final firstSegment = math.min(src.length, capacity - pos);
    _data.setRange(pos, pos + firstSegment, src);
    if (firstSegment < src.length) {
      _data.setRange(0, src.length - firstSegment, src, firstSegment);
    }
  }

  /// Copies [length] bytes out of the ring from [pos] in at most two segments.
  Uint8List _copyOut(int pos, int length) {
    final out = Uint8List(length);
    final firstSegment = math.min(length, capacity - pos);
    out.setRange(0, firstSegment, _data, pos);
    if (firstSegment < length) {
      out.setRange(firstSegment, length, _data, 0);
    }
    return out;
  }

  void _checkIndex(int value, String name) {
    if (value < 0 || value >= capacity) {
      throw RingCorruptionException('$name index $value is outside ring capacity $capacity');
    }
  }
}
