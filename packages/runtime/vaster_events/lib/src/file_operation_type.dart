/// Strongly-typed enum representing virtual filesystem operation types.
enum FileOperationType {
  read('read'),
  write('write'),
  delete('delete'),
  mount('mount'),
  unmount('unmount');

  final String name;

  const FileOperationType(this.name);

  static FileOperationType parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final op in FileOperationType.values) {
      if (op.name == lower) return op;
    }
    return FileOperationType.read;
  }

  @override
  String toString() => name;
}
