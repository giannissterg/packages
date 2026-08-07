import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';

void main() async {
  print('=== Vaster Filesystem Manager Example ===');

  final memFs = MemoryVasterFileSystem();
  await memFs.writeText('/mem/notes.txt', 'Memory note text');

  final manager = BasicFileSystemManager(mounts: {'/mem': memFs});

  print('Mounted paths: ${manager.mounts.keys.toList()}');

  final contextSource = await manager.toContextSource('/mem/notes.txt');
  print('Bridged Context Source: ${contextSource.name} (${contextSource.filePath})');
}
