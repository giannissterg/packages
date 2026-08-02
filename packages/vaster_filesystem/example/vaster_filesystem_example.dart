import 'package:vaster_filesystem/vaster_filesystem.dart';

void main() {
  print('=== Vaster Filesystem Types Example ===');

  final desc = FileDescriptor(
    path: '/workspace/ideas.md',
    sizeBytes: 2048,
    mimeType: 'text/markdown',
    modifiedTimestamp: DateTime.now(),
  );

  print('Descriptor: $desc');
}
