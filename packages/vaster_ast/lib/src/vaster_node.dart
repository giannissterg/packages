part of 'ast_lib.dart';

/// Sealed base class for all Vaster AST nodes.
///
/// The sealed modifier enables exhaustive `switch` statements in the compiler,
/// giving compile-time guarantees that every node type is handled.
///
/// Extend [ComposableNode] to create reusable, modular pipeline components.
/// Do not extend [VasterNode] directly.
sealed class VasterNode {
  const VasterNode();
}