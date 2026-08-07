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
  /// [ModelDescriptor] and returns the model it displaced under the
  /// descriptor key, null when fresh — a silent re-registration is
  /// observable (Rule 11).
  VasterModel? registerModel(ModelDescriptor descriptor, VasterModel model) {
    final displaced = _models[descriptor.descriptorKey];
    _models[descriptor.descriptorKey] = model;
    _models[descriptor.provider] = model;
    return displaced;
  }

  /// Resolves a concrete [VasterModel] for [descriptor].
  ///
  /// Returns the registered model matching [descriptor.descriptorKey] or
  /// [descriptor.provider], or falls back to [defaultModel].
  VasterModel? resolveModel(ModelDescriptor descriptor) {
    return _models[descriptor.descriptorKey] ??
        _models[descriptor.provider] ??
        _defaultModel;
  }

  /// Resolves a model by descriptor key or provider name.
  VasterModel? resolveByKey(String key) {
    return _models[key] ?? _defaultModel;
  }

  /// Returns `true` if a model for [descriptor] is registered.
  bool contains(ModelDescriptor descriptor) {
    return _models.containsKey(descriptor.descriptorKey) ||
        _models.containsKey(descriptor.provider);
  }
}
