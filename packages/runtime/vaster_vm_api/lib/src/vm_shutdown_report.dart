/// What [VasterVirtualMachine.shutdown] actually tore down — a named
/// contract, not an anonymous record (Rule 11: records never cross a
/// public boundary).
final class VmShutdownReport {
  final int sessionsClosed;
  final bool messagingClosed;
  final bool eventBusClosed;

  const VmShutdownReport({
    required this.sessionsClosed,
    required this.messagingClosed,
    required this.eventBusClosed,
  });

  /// The nothing-was-open teardown.
  static const empty = VmShutdownReport(sessionsClosed: 0, messagingClosed: false, eventBusClosed: false);

  @override
  String toString() =>
      'VmShutdownReport($sessionsClosed session(s), '
      'messaging ${messagingClosed ? 'closed' : 'already closed'}, '
      'bus ${eventBusClosed ? 'closed' : 'already closed'})';
}
