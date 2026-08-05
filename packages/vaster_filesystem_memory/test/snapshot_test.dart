import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';

/// Checkpoint capture/restore for memory mounts — binary-safe.
void main() {
  group('MemoryVasterFileSystem export/import', () {
    test('text and binary files round-trip through base64', () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/notes/a.txt', 'héllo — unicode ✓');
      await fs.writeBytes(
          '/bin/blob', Uint8List.fromList([0, 1, 255, 128, 7]));

      final restored = MemoryVasterFileSystem()
        ..importFilesBase64(fs.exportFilesBase64());

      expect(await restored.readText('/notes/a.txt'), 'héllo — unicode ✓');
      expect(await restored.readBytes('/bin/blob'),
          equals([0, 1, 255, 128, 7]));
    });

    test('import replaces same-path files and keeps others', () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/keep.txt', 'kept');
      await fs.writeText('/replace.txt', 'old');

      fs.importFilesBase64(
          (MemoryVasterFileSystem()..importFilesBase64(const {}))
              .exportFilesBase64());
      final donor = MemoryVasterFileSystem();
      await donor.writeText('/replace.txt', 'new');
      fs.importFilesBase64(donor.exportFilesBase64());

      expect(await fs.readText('/keep.txt'), 'kept');
      expect(await fs.readText('/replace.txt'), 'new');
    });
  });
}
