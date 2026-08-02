/// Process-like execution state lifecycle for scheduled VM tasks.
enum ExecutionState {
  created,
  queued,
  running,
  waiting,
  paused,
  completed,
  failed,
  cancelled,
  timedOut,
}
