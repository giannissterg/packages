# Changelog

## 0.2.0

- Initial version: `VasterVirtualMachine`, `VMConfig`, and `ModelRegistry`
  extracted from `vaster_vm` to break the runtime ⇄ vm dependency cycle —
  the runtime now depends on this interface package only; host-facing job
  scheduling stays on the engine.
