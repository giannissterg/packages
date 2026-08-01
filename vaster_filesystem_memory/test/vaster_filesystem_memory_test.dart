import 'package:test/test.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';

void main() {
  group('MemoryVasterFileSystem', () {
    test('readText and writeText CRUD operations', () async {
      final VasterFileSystem fs = MemoryVasterFileSystem();

      expect(await fs.exists('/test.txt'), isFalse);
      await fs.writeText('/test.txt', 'Hello Memory VFS');
      expect(await fs.exists('/test.txt'), isTrue);

      final content = await fs.readText('/test.txt');
      expect(content, equals('Hello Memory VFS'));

      final desc = await fs.getDescriptor('/test.txt');
      expect(desc?.path, equals('/test.txt'));
      expect(desc?.sizeBytes, equals('Hello Memory VFS'.length));
    });

    test('listDirectory lists files and nested directories', () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/src/main.dart', 'void main() {}');
      await fs.writeText('/src/util.dart', 'void util() {}');
      await fs.writeText('/README.md', '# Readme');

      final rootEntries = await fs.listDirectory('/');
      expect(rootEntries.map((e) => e.name), containsAll(['src', 'README.md']));

      final srcEntries = await fs.listDirectory('/src');
      expect(srcEntries.map((e) => e.name), containsAll(['main.dart', 'util.dart']));
    });

    test('createSnapshot and restoreSnapshot roll back state', () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/file1.txt', 'Version 1');

      final snapshot = await fs.createSnapshot();

      await fs.writeText('/file1.txt', 'Version 2 (Broken)');
      await fs.writeText('/file2.txt', 'Temporary file');
      expect(await fs.readText('/file1.txt'), equals('Version 2 (Broken)'));

      await fs.restoreSnapshot(snapshot);
      expect(await fs.readText('/file1.txt'), equals('Version 1'));
      expect(await fs.exists('/file2.txt'), isFalse);
    });
  });
}
