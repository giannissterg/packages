import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';

void main() async {
  print('=== Vaster Memory Filesystem Example ===');

  final VasterFileSystem fs = MemoryVasterFileSystem();

  await fs.writeText('/workspace/ideas.md', 'Virtual context & VM architecture.');
  print('Read text: ${await fs.readText('/workspace/ideas.md')}');

  final snapshot = await fs.createSnapshot();
  print('Snapshot files: ${snapshot.files.keys.toList()}');
}
