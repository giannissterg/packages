import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

/// The protocol layer, tested with zero FFI — a [Uint8List] and in-memory
/// indices are the whole world.
void main() {
  RingBuffer ring(int capacity, [RingIndices? indices]) => RingBuffer(
        data: Uint8List(capacity),
        indices: indices ?? MemoryRingIndices(),
      );

  group('RingBuffer basics', () {
    test('round-trips a frame and reports emptiness', () {
      final r = ring(64);
      expect(r.isEmpty, isTrue);
      expect(r.read(), isNull);

      r.write([1, 2, 3, 4, 5]);
      expect(r.isEmpty, isFalse);
      expect(r.read(), equals([1, 2, 3, 4, 5]));
      expect(r.isEmpty, isTrue);
      expect(r.read(), isNull);
    });

    test('preserves FIFO order across multiple frames', () {
      final r = ring(128);
      for (var i = 0; i < 5; i++) {
        r.write([i, i + 1, i + 2]);
      }
      for (var i = 0; i < 5; i++) {
        expect(r.read(), equals([i, i + 1, i + 2]));
      }
    });

    test('carries empty and single-byte frames', () {
      final r = ring(64);
      r.write(const []);
      r.write([42]);
      expect(r.read(), isEmpty);
      expect(r.read(), equals([42]));
    });

    test('rejects a capacity below the minimum', () {
      expect(() => ring(RingBuffer.minCapacity - 1), throwsArgumentError);
    });
  });

  group('RingBuffer wrap-around', () {
    test('frames survive crossing the physical end of the buffer', () {
      final r = ring(32);
      // Advance the cursors close to the end, draining as we go.
      r.write(List.filled(20, 7));
      expect(r.read(), hasLength(20));
      // This frame's prefix and payload both straddle the wrap point.
      final frame = List<int>.generate(20, (i) => i);
      r.write(frame);
      expect(r.read(), equals(frame));
    });

    test('sustains many fill-drain cycles at every wrap phase', () {
      final r = ring(48);
      for (var cycle = 0; cycle < 500; cycle++) {
        final frame = List<int>.generate(cycle % 30, (i) => (cycle + i) & 0xFF);
        r.write(frame);
        expect(r.read(), equals(frame), reason: 'cycle $cycle');
      }
    });

    test('interleaved writes and reads never corrupt frames', () {
      final r = ring(64);
      var next = 0;
      var expected = 0;
      for (var step = 0; step < 300; step++) {
        final frame = [next & 0xFF, (next >> 8) & 0xFF];
        if (r.tryWrite(frame)) next++;
        if (step.isOdd) {
          final got = r.read();
          if (got != null) {
            expect(got, equals([expected & 0xFF, (expected >> 8) & 0xFF]));
            expected++;
          }
        }
      }
      while (true) {
        final got = r.read();
        if (got == null) break;
        expect(got, equals([expected & 0xFF, (expected >> 8) & 0xFF]));
        expected++;
      }
      expect(expected, equals(next), reason: 'every written frame was read');
    });
  });

  group('RingBuffer backpressure', () {
    test('tryWrite refuses a frame that does not fit and writes nothing', () {
      final r = ring(32); // 31 usable bytes
      expect(r.tryWrite(List.filled(28, 1)), isFalse); // 4 + 28 > 31
      expect(r.isEmpty, isTrue);
      expect(r.tryWrite(List.filled(27, 1)), isTrue); // 4 + 27 == 31
      expect(r.freeBytes, equals(0));
    });

    test('write throws a typed RingFullException, not silent overwrite', () {
      final r = ring(32);
      r.write(List.filled(20, 9)); // 24 of 31 used
      expect(
        () => r.write(List.filled(10, 9)),
        throwsA(isA<RingFullException>().having((e) => e.frameLength, 'frameLength', 10)),
      );
      // The refused write must not have clobbered the unread frame.
      expect(r.read(), equals(List.filled(20, 9)));
    });

    test('space freed by the consumer becomes writable again', () {
      final r = ring(32); // 31 usable
      r.write(List.filled(20, 1)); // 24 used, 7 free
      expect(r.tryWrite([1, 2, 3, 4]), isFalse); // needs 8 > 7
      r.read();
      expect(r.tryWrite([1, 2, 3, 4]), isTrue);
      expect(r.read(), equals([1, 2, 3, 4]));
    });

    test('freeBytes and usedBytes account for prefixes', () {
      final r = ring(64); // 63 usable
      expect(r.freeBytes, equals(63));
      r.write([1, 2, 3]); // 4 + 3
      expect(r.usedBytes, equals(7));
      expect(r.freeBytes, equals(56));
      expect(r.maxFrameLength, equals(64 - 1 - RingBuffer.framePrefixBytes));
    });
  });

  group('RingBuffer corruption guards', () {
    test('a length prefix beyond the used region is detected', () {
      final data = Uint8List(32);
      final indices = MemoryRingIndices();
      final r = RingBuffer(data: data, indices: indices);
      // Hand-forge a frame whose prefix claims more than the ring holds.
      data[0] = 200; // little-endian length = 200
      indices.head = 6; // only 6 bytes "written"
      expect(r.read, throwsA(isA<RingCorruptionException>()));
    });

    test('out-of-range indices are detected instead of misindexing', () {
      final indices = MemoryRingIndices()..head = 999;
      final r = RingBuffer(data: Uint8List(32), indices: indices);
      expect(() => r.usedBytes, throwsA(isA<RingCorruptionException>()));
    });

    test('a partial frame (fewer bytes than a prefix) is detected', () {
      final indices = MemoryRingIndices()..head = 2;
      final r = RingBuffer(data: Uint8List(32), indices: indices);
      expect(r.read, throwsA(isA<RingCorruptionException>()));
    });
  });
}
