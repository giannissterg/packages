import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// Configuration settings used to initialize a [VasterVirtualMachine].
class VMConfig {
  /// Default model backend used when no target model is specified.
  final VasterModel defaultModel;

  /// Default resource quota applied to VM execution tasks.
  final ResourceQuota defaultQuota;

  /// Rate table used to compute monetary cost for backends that don't
  /// wire-report it. Defaults to the dated builtin rates; pass
  /// [PricingCatalog.empty] to disable computed cost entirely.
  final PricingCatalog pricingCatalog;

  /// Default root mount path prefix for memory filesystems.
  final String rootMountPath;

  /// Virtual core count for the VM's default scheduler: how many scheduled
  /// quanta may be in flight concurrently. Model I/O dominates this VM's
  /// latency, so cores > 1 lets one job's model call overlap another job's
  /// execution. Ignored when a custom scheduler is supplied at bootstrap.
  final int cores;

  /// Metadata attributes.
  final Map<String, dynamic> metadata;

  const VMConfig({
    required this.defaultModel,
    this.defaultQuota = ResourceQuota.unlimited,
    this.pricingCatalog = PricingCatalog.builtin,
    this.rootMountPath = '/mem',
    this.cores = 1,
    this.metadata = const {},
  });

  @override
  String toString() =>
      'VMConfig(model: "${defaultModel.modelName}", rootMount: "$rootMountPath")';
}
