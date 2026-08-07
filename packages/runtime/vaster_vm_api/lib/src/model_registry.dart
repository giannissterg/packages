import 'package:vaster_model/vaster_model.dart';

/// Central registry for registering and resolving [ModelDescriptor]s to concrete [VasterModel] backend instances.
class ModelRegistry {
  final Map<String, VasterModel> _models = {};
  VasterModel? _defaultModel;

  ModelRegistry({VasterModel? defaultModel}) : _defaultModel = defaultModel {
    if (defaultModel != null) {
      _models['default'] = defaultModel;
    }
  }

  /// The default fallback model.
  VasterModel? get defaultModel => _defaultModel;
  set defaultModel(VasterModel? model) {
    _defaultModel = model;
    if (model != null) {
      _models['default'] = model;
    }
  }

  /// Registers a concrete [VasterModel] backend for a given
  /// [ModelDescriptor] and returns EVERY binding it displaced, keyed by
  /// the slot displaced (`descriptorKey` and/or `provider`).
  ///
  /// Registration writes two slots — the exact descriptor key and the
  /// bare provider key that [resolveModel] falls back to — so reporting
  /// only one hid a real event: registering `anthropic:opus` silently
  /// evicted whatever was serving the bare `anthropic` key. A caller can
  /// now see both (Rule 11: report every displacement, not the first).
  Map<String, VasterModel> registerModel(ModelDescriptor descriptor, VasterModel model) {
    final displaced = <String, VasterModel>{};
    final byKey = _models[descriptor.descriptorKey];
    if (byKey != null) displaced[descriptor.descriptorKey] = byKey;
    final byProvider = _models[descriptor.provider];
    if (byProvider != null) displaced[descriptor.provider] = byProvider;
    _models[descriptor.descriptorKey] = model;
    _models[descriptor.provider] = model;
    return displaced;
  }

  /// Resolves a concrete [VasterModel] for [descriptor].
  ///
  /// Returns the registered model matching [descriptor.descriptorKey] or
  /// [descriptor.provider], or falls back to [defaultModel].
  VasterModel? resolveModel(ModelDescriptor descriptor) {
    return _models[descriptor.descriptorKey] ?? _models[descriptor.provider] ?? _defaultModel;
  }

  /// Resolves a model by descriptor key or provider name.
  VasterModel? resolveByKey(String key) {
    return _models[key] ?? _defaultModel;
  }

  /// Returns `true` if a model for [descriptor] is registered.
  bool contains(ModelDescriptor descriptor) {
    return _models.containsKey(descriptor.descriptorKey) || _models.containsKey(descriptor.provider);
  }
}
