import 'dart:async';
import 'package:vaster_model/vaster_model.dart';
import 'context_region.dart';

/// Abstract sealed class representing a virtual context source provider.
sealed class ContextSource {
  final String id;
  final String name;

  const ContextSource({
    required this.id,
    required this.name,
  });

  /// Asynchronously fetches or resolves context regions from this source.
  FutureOr<List<ContextRegion>> getRegions();
}

/// A context source providing in-memory key-value context or variable bindings.
class MemoryContextSource extends ContextSource {
  final Map<String, String> data;

  MemoryContextSource({
    required super.id,
    super.name = 'memory_source',
    this.data = const {},
  });

  @override
  List<ContextRegion> getRegions() {
    return data.entries.map((entry) {
      return ContextRegion.text(
        id: '${id}_${entry.key}',
        label: 'Memory (${entry.key})',
        role: entry.key == 'system' ? Role.system : Role.user,
        text: '${entry.key}: ${entry.value}',
      );
    }).toList();
  }
}

/// A context source managing past chat turn history.
class ConversationContextSource extends ContextSource {
  final List<ContextRegion> historyRegions;

  ConversationContextSource({
    required super.id,
    super.name = 'conversation_history',
    this.historyRegions = const [],
  });

  @override
  List<ContextRegion> getRegions() => List.unmodifiable(historyRegions);
}

/// A context source representing virtual file or document content.
class FileContextSource extends ContextSource {
  final String filePath;
  final String content;

  FileContextSource({
    required super.id,
    required this.filePath,
    required this.content,
    super.name = 'file_source',
  });

  @override
  List<ContextRegion> getRegions() {
    return [
      ContextRegion.text(
        id: id,
        label: 'File: $filePath',
        role: Role.user,
        text: '--- File: $filePath ---\n$content',
      )
    ];
  }
}
