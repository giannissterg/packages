import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Interface for compiling a high-level Vaster AST into low-level ISA bytecode.
abstract interface class WorkflowCompiler {
  /// Compiles a [Pipeline] AST into a serializable [VasterProgram] (ISA bytecode).
  VasterProgram compile(Pipeline pipeline);
}
