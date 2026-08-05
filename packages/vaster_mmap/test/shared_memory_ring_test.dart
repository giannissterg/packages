import 'package:test/test.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

/// Integration tests for the shm-backed ring: ownership semantics,
/// cross-instance visibility through real mapped pages, and backpressure at
/// the public surface.
void main() {
  var seq = 0;
  String freshName() =>
      '/vring_${DateTime.now().microsecondsSinceEpoch}_${seq++}';

  group('SharedMemoryRing ownership', () {
    test('creator is owner; second open of the same name attaches', () {
      final name = freshName();
      final owner = SharedMemoryRing(shmName: name, capacity: 4096);
      addTearDown(owner.close);
      expect(owner.isOwner, isTrue);

      final attacher = SharedMemoryRing(shmName: name, capacity: 4096);
      addTearDown(attacher.close);
      expect(attacher.isOwner, isFalse);
    });

    test('frames written by one instance are read through the other', () {
      final name = freshName();
      final producer = SharedMemoryRing(shmName: name, capacity: 4096);
      addTearDown(producer.close);
      final consumer = SharedMemoryRing(shmName: name, capacity: 4096);
      addTearDown(() => consumer.close());

      producer.writeString('across the mapping');
      expect(consumer.readString(), equals('across the mapping'));
      expect(consumer.readString(), isNull);
    });

    test("attacher close does not destroy the owner's segment", () {
      final name = freshName();
      final owner = SharedMemoryRing(shmName: name, capacity: 4096);
      addTearDown(owner.close);

      final attacher = SharedMemoryRing(shmName: name, capacity: 4096);
      owner.writeString('still here');
      attacher.close(); // detach only — must not unlink

      // The segment must still exist and hold the frame: a new attach sees it.
      final reattached = SharedMemoryRing.attach(name);
      addTearDown(() => reattached.close());
      expect(reattached.isOwner, isFalse);
      expect(reattached.readString(), equals('still here'));
    });

    test('attach() without capacity learns it from the header', () {
      final name = freshName();
      final owner = SharedMemoryRing(shmName: name, capacity: 8192);
      addTearDown(owner.close);

      final attached = SharedMemoryRing.attach(name);
      addTearDown(() => attached.close());
      expect(attached.capacity, equals(8192));
    });

    test('attach() to a nonexistent ring throws instead of creating one', () {
      expect(() => SharedMemoryRing.attach(freshName()), throwsStateError);
    });

    test('capacity mismatch on attach throws before touching the payload',
        () {
      final name = freshName();
      final owner = SharedMemoryRing(shmName: name, capacity: 4096);
      addTearDown(owner.close);
      expect(
        () => SharedMemoryRing(shmName: name, capacity: 8192),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('capacity'))),
      );
    });

    test('close is idempotent', () {
      final ring = SharedMemoryRing(shmName: freshName(), capacity: 4096);
      ring.close();
      ring.close();
    });
  });

  group('SharedMemoryRing backpressure', () {
    test('a full ring throws RingFullException instead of corrupting', () {
      final ring = SharedMemoryRing(shmName: freshName(), capacity: 64);
      addTearDown(ring.close);

      ring.writePacket(List.filled(40, 1));
      expect(() => ring.writePacket(List.filled(40, 2)),
          throwsA(isA<RingFullException>()));
      // The unread frame survived the refused write.
      expect(ring.readPacket(), equals(List.filled(40, 1)));
      // And the freed space is writable again.
      expect(ring.tryWritePacket(List.filled(40, 2)), isTrue);
      expect(ring.readPacket(), equals(List.filled(40, 2)));
    });

    test('tryWriteString reports fullness without throwing', () {
      final ring = SharedMemoryRing(shmName: freshName(), capacity: 32);
      addTearDown(ring.close);
      expect(ring.tryWriteString('x' * 40), isFalse);
      expect(ring.tryWriteString('fits'), isTrue);
      expect(ring.readString(), equals('fits'));
    });

    test('sustained duplex traffic over two rings stays consistent', () {
      final req = SharedMemoryRing(shmName: freshName(), capacity: 1024);
      final res = SharedMemoryRing(shmName: freshName(), capacity: 1024);
      addTearDown(req.close);
      addTearDown(res.close);

      for (var i = 0; i < 200; i++) {
        req.writeString('request $i');
        expect(req.readString(), equals('request $i'));
        res.writeString('response $i');
        expect(res.readString(), equals('response $i'));
      }
      expect(req.isEmpty, isTrue);
      expect(res.isEmpty, isTrue);
    });
  });
}
