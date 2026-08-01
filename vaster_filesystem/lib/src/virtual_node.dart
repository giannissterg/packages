import 'dart:typed_data';
import 'file_descriptor.dart';

/// Sealed class hierarchy representing a node (file or directory) in a virtual filesystem tree.
sealed class VirtualNode {
  final String path;
  final String name;

  const VirtualNode({
    required this.path,
    required this.name,
  });
}

/// Represents a file node.
final class VirtualFile extends VirtualNode {
  final FileDescriptor descriptor;
  final Uint8List bytes;

  VirtualFile({
    required super.path,
    required super.name,
    required this.descriptor,
    required this.bytes,
  });

  /// String view of file content.
  String get text => String.fromCharCodes(bytes);

  @override
  String toString() => 'VirtualFile("$path", ${bytes.length}B)';
}

/// Represents a directory node.
final class VirtualDirectory extends VirtualNode {
  final List<VirtualNode> children;

  const VirtualDirectory({
    required super.path,
    required super.name,
    this.children = const [],
  });

  @override
  String toString() => 'VirtualDirectory("$path", children: ${children.length})';
}
