import 'package:vaster_instruction/vaster_instruction.dart';

import 'runtime_status.dart';

/// The machine's execution phase, modeled as data.
///
/// [RuntimeStatus] answers "which state?"; this sealed hierarchy also
/// answers the question each state raises — a pause *carries* its request, a
/// trap *carries* its details, a timeout *carries* its reason — instead of
/// scattering them across an enum, an error-string side channel, and a
/// separate getter. Exhaustive switches over it are compiler-checked; the
/// legacy enum survives as the [asStatus] projection (the same move
/// `AgentLifecycle.asState` made).
sealed class MachinePhase {
  const MachinePhase();

  /// Projection onto the legacy [RuntimeStatus] enum.
  RuntimeStatus get asStatus;

  /// Failure detail for phases that carry one ([PhaseTrapped],
  /// [PhaseTimedOut]); null otherwise.
  String? get errorDetails => null;
}

/// Constructed, nothing executed yet.
final class PhaseIdle extends MachinePhase {
  const PhaseIdle();

  @override
  RuntimeStatus get asStatus => RuntimeStatus.idle;
}

/// The fetch-decode loop is (or is about to be) driving instructions.
final class PhaseRunning extends MachinePhase {
  const PhaseRunning();

  @override
  RuntimeStatus get asStatus => RuntimeStatus.running;
}

/// The program retired through [HaltOp] or fell off its end.
final class PhaseHalted extends MachinePhase {
  const PhaseHalted();

  @override
  RuntimeStatus get asStatus => RuntimeStatus.halted;
}

/// Yielded for a human — the pause carries the request it is waiting on.
final class PhasePausedForHuman extends MachinePhase {
  final HumanInteractionRequest request;

  const PhasePausedForHuman({required this.request});

  @override
  RuntimeStatus get asStatus => RuntimeStatus.pausedForHuman;
}

/// The machine trapped — the phase carries the trap report.
final class PhaseTrapped extends MachinePhase {
  final String details;

  const PhaseTrapped({required this.details});

  @override
  RuntimeStatus get asStatus => RuntimeStatus.error;

  @override
  String? get errorDetails => details;
}

/// The host budget expired at an instruction boundary (soft stop).
final class PhaseTimedOut extends MachinePhase {
  final String reason;

  const PhaseTimedOut({required this.reason});

  @override
  RuntimeStatus get asStatus => RuntimeStatus.timedOut;

  @override
  String? get errorDetails => reason;
}
