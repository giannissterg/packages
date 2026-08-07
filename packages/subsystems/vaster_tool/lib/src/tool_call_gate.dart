/// Gates one tool call before it executes (A1: BOTH tool loops — the
/// runtime's ISA loop and the agent's internal loop — pass every call
/// through this seam, so guard coverage can never silently diverge
/// between them again).
///
/// Pure tool domain: a gate maps a tool name to a permission decision.
/// It knows nothing of policies' internals, models, or the ISA (Rule 6.5)
/// — implementations adapt whatever authority they represent (the
/// program's execution policy, an agent descriptor's policy) and THROW
/// their own typed violation when the call is denied.
abstract interface class ToolCallGate {
  /// Permits the call and echoes the permitted [toolName] (Rule 11), or
  /// throws the implementation's violation type. Security throws must be
  /// uncatchable by retry machinery — implementations adapt exceptions
  /// their runtimes already treat as traps.
  String permit(String toolName);
}

/// The canonical pass-through default (Rule 5).
final class NoopToolCallGate implements ToolCallGate {
  const NoopToolCallGate();

  @override
  String permit(String toolName) => toolName;
}

/// A LIST of gates, encapsulated as a gate — the composite is the
/// higher-order feature, not a loop at every call site: every member
/// must permit, in order, first refusal throws.
final class CompositeToolCallGate implements ToolCallGate {
  final List<ToolCallGate> gates;

  const CompositeToolCallGate(this.gates);

  @override
  String permit(String toolName) {
    for (final gate in gates) {
      gate.permit(toolName);
    }
    return toolName;
  }
}

/// A stable indirection for wiring-order freedom — the same pattern as
/// `ToolEffectRecorderBinding` (GAP-3a): agents hold this binding
/// eagerly; the executing runtime binds the program's policy gate once
/// it exists. Unbound, it permits everything.
final class ToolCallGateBinding implements ToolCallGate {
  ToolCallGate _bound;

  ToolCallGateBinding([this._bound = const NoopToolCallGate()]);

  /// Binds [gate] and returns the gate it displaced (Rule 11).
  ToolCallGate bind(ToolCallGate gate) {
    final previous = _bound;
    _bound = gate;
    return previous;
  }

  @override
  String permit(String toolName) => _bound.permit(toolName);
}
