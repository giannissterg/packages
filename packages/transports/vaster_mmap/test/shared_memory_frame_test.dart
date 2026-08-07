import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

/// The frame as a composition over ShmSegment + SegmentTag: creation,
/// content-addressed idempotency, attach probing, and lifetime semantics.
void main() {
  var seq = 0;
  String freshName() => '/vframe_${DateTime.now().microsecondsSinceEpoch}_${seq++}';

  Uint8List payloadOf(String text) => Uint8List.fromList(text.codeUnits);

  group('SharedMemoryFrame create/attach', () {
    test('round-trips payload and meta through separate mappings', () {
      final name = freshName();
      final creator = SharedMemoryFrame.create(name, payloadOf('kv state'), meta: 128);
      addTearDown(() => creator.close(unlink: true));
      expect(creator.isOwner, isTrue);

      final attached = SharedMemoryFrame.attach(name);
      addTearDown(attached.close);
      expect(attached.isOwner, isFalse);
      expect(attached.payloadLength, equals(8));
      expect(attached.meta, equals(128));
      expect(String.fromCharCodes(attached.bytes), equals('kv state'));
    });

    test('attach to a nonexistent frame throws instead of creating one', () {
      expect(() => SharedMemoryFrame.attach(freshName()), throwsStateError);
    });

    test('create on an existing frame attaches idempotently (same length)', () {
      final name = freshName();
      final first = SharedMemoryFrame.create(name, payloadOf('same-content'), meta: 7);
      addTearDown(() => first.close(unlink: true));

      // A peer materializing the same fingerprint races us benignly: it must
      // get the existing frame back, not overwrite live pages.
      final second = SharedMemoryFrame.create(name, payloadOf('XXXX-content'));
      addTearDown(second.close);
      expect(second.isOwner, isFalse);
      expect(second.meta, equals(7), reason: 'existing header wins');
      expect(String.fromCharCodes(second.bytes), equals('same-content'),
          reason: 'existing payload must not be rewritten');
    });

    test('create on an existing frame with a different length throws', () {
      final name = freshName();
      final first = SharedMemoryFrame.create(name, payloadOf('short'));
      addTearDown(() => first.close(unlink: true));
      expect(
        () => SharedMemoryFrame.create(name, payloadOf('much longer payload')),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('content-addressed'))),
      );
    });
  });

  group('SharedMemoryFrame lifetime', () {
    test('close detaches by default — the frame remains discoverable', () {
      final name = freshName();
      SharedMemoryFrame.create(name, payloadOf('at rest')).close();

      final rediscovered = SharedMemoryFrame.attach(name);
      expect(String.fromCharCodes(rediscovered.bytes), equals('at rest'));
      rediscovered.close(unlink: true);
    });

    test('close(unlink: true) destroys the frame', () {
      final name = freshName();
      SharedMemoryFrame.create(name, payloadOf('gone')).close(unlink: true);
      expect(() => SharedMemoryFrame.attach(name), throwsStateError);
    });

    test('writes through the creator view are visible to the attacher', () {
      final name = freshName();
      final creator = SharedMemoryFrame.create(name, Uint8List.fromList([1, 2, 3, 4]));
      addTearDown(() => creator.close(unlink: true));
      final attached = SharedMemoryFrame.attach(name);
      addTearDown(attached.close);

      creator.bytes[2] = 99; // same physical pages
      expect(attached.bytes, equals([1, 2, 99, 4]));
    });
  });
}
