import 'package:vaster_instruction/vaster_instruction.dart';

/// Severity of a compile-time diagnostic.
enum CompileSeverity { error, warning, info }

/// A single diagnostic produced by compilation or program analysis.
class CompileDiagnostic {
  final CompileSeverity severity;

  /// Stable machine-readable code (e.g. `read_before_write`, `unreachable_code`).
  final String code;

  /// Human-readable explanation.
  final String message;

  /// Program counter the diagnostic anchors to, when applicable.
  final int? pc;

  const CompileDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.pc,
  });

  @override
  String toString() =>
      '${severity.name}[$code]${pc != null ? ' @PC$pc' : ''}: $message';
}

/// The result of compiling a pipeline: the program plus every diagnostic
/// gathered by the analysis passes.
class CompileResult {
  final VasterProgram program;
  final List<CompileDiagnostic> diagnostics;

  const CompileResult({required this.program, required this.diagnostics});

  bool get hasErrors =>
      diagnostics.any((d) => d.severity == CompileSeverity.error);

  Iterable<CompileDiagnostic> get errors =>
      diagnostics.where((d) => d.severity == CompileSeverity.error);

  Iterable<CompileDiagnostic> get warnings =>
      diagnostics.where((d) => d.severity == CompileSeverity.warning);
}

/// Options controlling the compiler's pass pipeline.
class CompilerOptions {
  /// Runs peephole optimizations (jump-to-next elimination, dead code removal).
  final bool optimize;

  /// Infers `responseSchema` on model ops whose outputs feed [JsonExtractOp]s.
  final bool inferSchemas;

  const CompilerOptions({this.optimize = false, this.inferSchemas = true});

  static const defaults = CompilerOptions();
}
