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

    test('transactions NEST: inner commit keeps the outer rollback intact',
        () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/data.json', 'v1');
      final manager = BasicFileSystemManager(mounts: {'/': fs});

      await manager.beginTransaction(); // outer
      await fs.writeText('/data.json', 'v2');
      await manager.beginTransaction(); // inner
      expect(manager.transactionDepth, 2);
      await fs.writeText('/data.json', 'v3');
      await manager.commit(); // inner commits — v3 stands for now
      expect(manager.transactionDepth, 1);
      expect(await fs.readText('/data.json'), 'v3');

      // The flat implementation cleared the outer snapshot here, turning
      // this rollback into a silent no-op. It must restore v1.
      await manager.rollback();
      expect(manager.transactionDepth, 0);
      expect(await fs.readText('/data.json'), 'v1');
    });

    test('inner rollback restores to the inner begin, not the outer one',
        () async {
      final fs = MemoryVasterFileSystem();
      await fs.writeText('/data.json', 'v1');
      final manager = BasicFileSystemManager(mounts: {'/': fs});

      await manager.beginTransaction(); // outer
      await fs.writeText('/data.json', 'v2');
      await manager.beginTransaction(); // inner
      await fs.writeText('/data.json', 'v3');

      await manager.rollback(); // inner: back to v2
      expect(await fs.readText('/data.json'), 'v2');
      await manager.commit(); // outer commits — v2 durable
      expect(await fs.readText('/data.json'), 'v2');
      expect(manager.transactionDepth, 0);
    });
  });
}
