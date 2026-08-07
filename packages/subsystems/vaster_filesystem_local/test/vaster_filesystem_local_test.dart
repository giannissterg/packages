import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_local/vaster_filesystem_local.dart';

void main() {
  group('LocalVasterFileSystem', () {
    late Directory tempDir;
    late VasterFileSystem fs;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vaster_fs_test_');
      fs = LocalVasterFileSystem(tempDir.path);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('readText and writeText on disk', () async {
      expect(await fs.exists('sample.txt'), isFalse);

      await fs.writeText('sample.txt', 'Hello Disk VFS');
      expect(await fs.exists('sample.txt'), isTrue);

      final text = await fs.readText('sample.txt');
      expect(text, equals('Hello Disk VFS'));

      final desc = await fs.getDescriptor('sample.txt');
      expect(desc?.path, equals('/sample.txt'));
      expect(desc?.sizeBytes, equals('Hello Disk VFS'.length));
    });

    test('listDirectory and createSnapshot on disk', () async {
      await fs.writeText('docs/ideas.md', 'Ideas content');
      await fs.writeText('src/main.dart', 'void main() {}');

      final entries = await fs.listDirectory('docs');
      expect(entries.map((e) => e.name), contains('ideas.md'));

      final snapshot = await fs.createSnapshot();
      expect(snapshot.files.keys, contains('/docs/ideas.md'));

      await fs.writeText('docs/ideas.md', 'Modified ideas');
      await fs.restoreSnapshot(snapshot);
      expect(await fs.readText('docs/ideas.md'), equals('Ideas content'));
    });
  });
}
