import 'package:test/test.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';

void main() {
  group('BasicFileSystemManager', () {
    test('mounts and resolves filesystem backends by path prefix', () async {
      final fsMem = MemoryVasterFileSystem();
      await fsMem.writeText('/mem/notes.txt', 'Memory note');

      final fsWork = MemoryVasterFileSystem();
      await fsWork.writeText('/workspace/ideas.md', 'Workspace ideas');

      final FileSystemManager manager = BasicFileSystemManager(mounts: {
        '/mem': fsMem,
        '/workspace': fsWork,
      });

      expect(manager.mounts.length, equals(2));
      expect(manager.resolveFileSystem('/mem/notes.txt'), equals(fsMem));
      expect(manager.resolveFileSystem('/workspace/ideas.md'), equals(fsWork));

      final text = await manager.resolveFileSystem('/mem/notes.txt').readText('/mem/notes.txt');
      expect(text, equals('Memory note'));
    });

    test('toContextSource bridges VFS files to FileContextSource', () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/doc.txt', 'Document for context manager.');

      final manager = BasicFileSystemManager(mounts: {'/': fs});
      final contextSource = await manager.toContextSource('/doc.txt');

      expect(contextSource.filePath, equals('/doc.txt'));
      expect(contextSource.content, equals('Document for context manager.'));
    });

    test('beginTransaction and rollback restore mounted filesystems', () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/data.json', '{"version": 1}');

      final manager = BasicFileSystemManager(mounts: {'/': fs});

      await manager.beginTransaction();
      await fs.writeText('/data.json', '{"version": 2}');
      expect(await fs.readText('/data.json'), contains('version": 2'));

      await manager.rollback();
      expect(await fs.readText('/data.json'), contains('version": 1'));
    });
  });
}
