import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Interface for compiling a high-level Vaster Workflow AST into low-level ISA bytecode.
abstract interface class WorkflowCompiler {
  /// Compiles a [PipelineNode] AST into a serializable [VasterProgram] (ISA bytecode).
  VasterProgram compile(PipelineNode pipeline);
}
