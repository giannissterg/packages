part of '../vaster_ast.dart';

/// Flutter-style composable node for defining reusable, modular pipeline components.
///
/// Analogous to Flutter's `StatelessWidget`. Subclass [ComposableNode] to define
/// a reusable pipeline component. The compiler will call [build] with the current
/// [BuildContext] and recursively compile the returned [WorkflowAstNode] sub-tree.
///
/// Because [ComposableNode] is abstract and part of the sealed [WorkflowAstNode]
/// hierarchy, the compiler handles it in an exhaustive switch by calling [build].
///
/// Example:
/// ```dart
/// class CodeReviewComponent extends ComposableNode {
///   final String filePath;
///   final String reviewerRoleId;
///
///   const CodeReviewComponent({
///     required this.filePath,
///     required this.reviewerRoleId,
///   });
///
///   @override
///   WorkflowAstNode build(BuildContext context) {
///     final cfg = context.tryRead<ReviewConfig>();
///     return StepTransactionNode(bodyNodes: [
///       PerformTaskNode(
///         agentRoleId: reviewerRoleId,
///         task: TaskDefinition(
///           taskId: 'review',
///           promptText: 'Review $filePath',
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
  /// Use [context.read<T>()] to access typed values injected by ancestor [ProviderNode]s.
  WorkflowAstNode build(BuildContext context);
}
