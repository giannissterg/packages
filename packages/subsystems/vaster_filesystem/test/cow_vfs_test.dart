import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';

void main() {
  group('Copy-on-Write (COW) Virtual Filesystem Snapshots', () {
    test('CowFileSnapshot.fork shares page byte buffer references without re-allocating', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final parent = CowFileSnapshot(
        pages: {'/workspace/main.dart': bytes},
        dirtyPaths: {},
        deletedPaths: {},
      );

      final child = CowFileSnapshot.fork(parent);

      // Verify zero-allocation pointer equality
      expect(identical(child.pages['/workspace/main.dart'], bytes), isTrue);
      expect(child.dirtyPaths, isEmpty);
      expect(child.deletedPaths, isEmpty);
    });
  });
}
