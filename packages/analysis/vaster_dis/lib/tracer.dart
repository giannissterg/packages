/// Live disassembly-style execution tracing.
///
/// A separate entrypoint from `package:vaster_dis/vaster_dis.dart` on
/// purpose: the core disassembler is a pure bytecode tool with no runtime
/// coupling, while the tracer attaches to a live [VasterRuntime]. Import this
/// library only when you have a runtime to trace.
library;

export 'src/execution_tracer.dart';
