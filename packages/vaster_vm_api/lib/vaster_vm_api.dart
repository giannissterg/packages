/// The VM's subsystem surface: the [VasterVirtualMachine] interface,
/// [VMConfig], and the [ModelRegistry] — everything the ISA runtime
/// programs against, with no dependency on the concrete engine.
///
/// Host-facing job scheduling (submitProgram / runScheduledJobs) lives on
/// the engine in `vaster_vm`; the runtime never calls it.
library;

export 'src/model_registry.dart';
export 'src/vaster_vm_interface.dart';
export 'src/vm_config.dart';
