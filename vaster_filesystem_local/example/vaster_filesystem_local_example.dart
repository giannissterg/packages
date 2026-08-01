import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_local/vaster_filesystem_local.dart';

void main() async {
  print('=== Vaster Local Filesystem Example ===');

  final VasterFileSystem fs = LocalVasterFileSystem('.');
  final descriptor = await fs.getDescriptor('ideas.md');
  print('Descriptor for ideas.md: $descriptor');
}
