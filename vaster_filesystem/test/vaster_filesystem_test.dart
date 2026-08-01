import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';

void main() {
  group('FileDescriptor & VirtualNode & FileSystemSnapshot', () {
    test('FileDescriptor json roundtrip', () {
      final desc = FileDescriptor(
        path: '/workspace/ideas.md',
        sizeBytes: 1024,
        mimeType: 'text/markdown',
        modifiedTimestamp: DateTime(2026, 8, 1),
      );

      final json = desc.toJson();
      final restored = FileDescriptor.fromJson(json);

      expect(restored.path, equals('/workspace/ideas.md'));
      expect(restored.sizeBytes, equals(1024));
      expect(restored.mimeType, equals('text/markdown'));
    });

    test('VirtualNode sealed matching', () {
      final bytes = Uint8List.fromList('Hello Virtual VFS'.codeUnits);
      final desc = FileDescriptor(
        path: 'hello.txt',
        sizeBytes: bytes.length,
        modifiedTimestamp: DateTime.now(),
      );

      final VirtualNode node = VirtualFile(
        path: 'hello.txt',
        name: 'hello.txt',
        descriptor: desc,
        bytes: bytes,
      );

      final typeLabel = switch (node) {
        VirtualFile(text: final t) => 'file: $t',
        VirtualDirectory() => 'dir',
      };

      expect(typeLabel, equals('file: Hello Virtual VFS'));
    });

    test('FileSystemSnapshot immutability', () {
      final snapshot = FileSystemSnapshot(
        files: {
          'file1.txt': Uint8List.fromList([65, 66]),
        },
      );

      expect(snapshot.files.length, equals(1));
      expect(String.fromCharCodes(snapshot.files['file1.txt']!), equals('AB'));
    });
  });
}
