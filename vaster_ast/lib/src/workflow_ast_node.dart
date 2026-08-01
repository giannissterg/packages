/// Abstract base class for all Vaster Workflow AST nodes.
///
/// Every node in the Workflow Abstract Syntax Tree extends this class.
/// Sealed sub-hierarchy covers all concrete node types.
/// Use [ComposableNode] to define reusable, modular node components.
abstract class WorkflowAstNode {
  const WorkflowAstNode();
}
