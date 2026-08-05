# Vaster v0.4.0

This release closes the machine-state and durable-execution threads and opens a third: static verification.

- **Machine-state architecture (MS-P2/P3/P4/P5/P6):** machine state is componentized, the inbox is durable with an enforcement gate, and `MachinePhase` is a sealed lifecycle.
- **Durable execution (DE-P5):** war-room durability, on top of the checkpoint/resume foundation from v0.3.0 (`vaster_checkpoint`, `run --checkpoint-dir`, `vaster resume`).
- **`vaster check`:** static verification as a first-class command.
- **Carried forward:** the time-travel debugger from v0.2.0 and typed bindings (Binding/Template/Cond, 2026-08-05). TT-P4 resume remains open.

Upgrading from v0.3.0: the checkpoint directory format and `vaster resume` entry point are unchanged. New surface area is `vaster check` and the sealed `MachinePhase` type.