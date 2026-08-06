/// The machine-state contract: every state-bearing component of the Vaster
/// machine snapshots itself; the whole machine is a fold over its components.
///
/// Born from a checkpoint bug: state living in named components
/// (`RegisterFile`, `CallStack`) survived suspension on the first try; state
/// living in loose fields on the runtime was silently lost. The contract
/// makes the difference structural — machine state may only live inside a
/// [MachineStateComponent] registered in the runtime's single component
/// list.
library;

export 'src/error_handler_frame.dart';
export 'src/machine_snapshot.dart';
export 'src/machine_state_component.dart';
