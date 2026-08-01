import 'build_context.dart';
import 'workflow_ast_node.dart';

/// Flutter-style composable node for defining reusable, modular pipeline components.
///
/// Analogous to Flutter's `StatelessWidget`. Subclass [ComposableNode] to define
/// a reusable pipeline component. The compiler will call [build] with the current
/// [BuildContext] and recursively compile the returned [WorkflowAstNode] sub-tree.
///
/// Example:
/// ```dart
/// class CodeReviewComponent extends ComposableNode {
///   final String sourceFilePath;
///   final String reviewerRoleId;
///
///   const CodeReviewComponent({
///     required this.sourceFilePath,
///     required this.reviewerRoleId,
///   });
///
///   @override
///   WorkflowAstNode build(BuildContext context) {
///     return StepTransactionNode(bodyNodes: [
///       PerformTaskNode(
///         agentRoleId: reviewerRoleId,
///         task: TaskDefinition(
///           taskId: 'review',
///           promptText: 'Review $sourceFilePath for issues',
///           outputVariable: 'review_result',
///         ),
///       ),
///     ]);
///   }
/// }
/// ```
abstract class ComposableNode extends WorkflowAstNode {
  const ComposableNode();

  /// Builds and returns the resolved AST sub-tree for this node.
  ///
  /// The returned node is recursively compiled by the compiler.
  WorkflowAstNode build(BuildContext context);
}
