/// Whole-machine durable checkpoints: suspend a running pipeline to
/// self-contained JSON, kill the process, resume in a fresh VM.
library;

export 'src/machine_checkpoint.dart';
export 'src/session_snapshot.dart';
