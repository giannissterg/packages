import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// Configuration settings used to initialize a [VasterVirtualMachine].
class VMConfig {
  /// Default model backend used when no target model is specified.
  final VasterModel defaultModel;

  /// Default resource quota applied to VM execution tasks.
  final ResourceQuota defaultQuota;

  /// Default root mount path prefix for memory filesystems.
  final String rootMountPath;

  /// Metadata attributes.
  final Map<String, dynamic> metadata;

  const VMConfig({
    required this.defaultModel,
    this.defaultQuota = ResourceQuota.unlimited,
    this.rootMountPath = '/mem',
    this.metadata = const {},
  });

  @override
  String toString() =>
      'VMConfig(model: "${defaultModel.modelName}", rootMount: "$rootMountPath")';
}
