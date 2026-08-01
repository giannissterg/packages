part of '../vaster_ast.dart';

/// Sealed base class for all Vaster Workflow AST nodes.
///
/// The sealed modifier enables exhaustive `switch` statements in the compiler,
/// giving compile-time guarantees that every node type is handled.
///
/// Extend [ComposableNode] to create reusable, modular pipeline components.
/// Do not extend [WorkflowAstNode] directly.
sealed class WorkflowAstNode {
  const WorkflowAstNode();
}
