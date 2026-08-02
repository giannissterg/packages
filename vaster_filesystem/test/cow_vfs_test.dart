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

    test('CowTransactionState records Copy-on-Write page modifications and deletions', () {
      final initialBytes = Uint8List.fromList([10, 20]);
      final initial = CowFileSnapshot(
        pages: {'/workspace/file1.txt': initialBytes},
        dirtyPaths: {},
        deletedPaths: {},
      );

      final state = CowTransactionState(
        transactionId: 1,
        initialSnapshot: initial,
      );

      final newBytes = Uint8List.fromList([99, 100]);
      state.recordWrite('/workspace/file2.txt', newBytes);

      expect(state.currentSnapshot.dirtyPaths, contains('/workspace/file2.txt'));
      expect(state.currentSnapshot.pages['/workspace/file2.txt'], equals(newBytes));

      state.recordDelete('/workspace/file1.txt');
      expect(state.currentSnapshot.deletedPaths, contains('/workspace/file1.txt'));
      expect(state.currentSnapshot.pages.containsKey('/workspace/file1.txt'), isFalse);
    });
  });
}
