# Changelog

## 0.3.0

- Initial release: `MachineStateComponent` (the snapshot contract every
  state-bearing machine component implements), `MachineSnapshot` (the whole
  machine at an instruction boundary, keyed by component), and
  `ErrorHandlerFrame`. Born from the DE-P2 checkpoint bug: state living in
  named components survived suspension; state living in loose fields was
  silently lost.
