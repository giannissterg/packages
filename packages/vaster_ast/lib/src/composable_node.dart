part of '../vaster_ast.dart';

/// Flutter-style composable node for defining reusable, modular pipeline components.
///
/// Analogous to Flutter's `StatelessWidget`. Subclass [ComposableNode] to define
/// a reusable pipeline component. The compiler will call [build] with the current
/// [BuildContext] and recursively compile the returned [VasterNode] sub-tree.
///
/// Because [ComposableNode] is abstract and part of the sealed [VasterNode]
/// hierarchy, the compiler handles it in an exhaustive switch by calling [build].
///
/// Example:
/// ```dart
/// class CodeReviewComponent extends ComposableNode {
///   final String filePath;
///   final AgentRole reviewer;
///
///   const CodeReviewComponent({
///     required this.filePath,
///     required this.reviewer,
///   });
///
///   @override
///   VasterNode build(BuildContext context) {
///     final cfg = context.tryRead<ReviewConfig>();
///     return Sequence([
///       ReadFile(path: filePath, output: 'source'),
///       Task(
///         agent: reviewer,
///         prompt: 'Review this file:\n\${source}',
///         output: 'review_result',
///       ),
///     ]);
///   }
/// }
/// ```
abstract class ComposableNode extends VasterNode {
  const ComposableNode();

  /// Builds and returns the resolved AST sub-tree for this node.
  ///
  /// Use [context.read<T>()] to access typed values injected by ancestor [Provider]s.
  VasterNode build(BuildContext context);
}

/// Inline functional component builder extending [ComposableNode].
///
/// Allows creating lightweight functional components via a closure `(context) => VasterNode`.
final class Component extends ComposableNode {
  final VasterNode Function(BuildContext context) builder;

  const Component(this.builder);

  @override
  VasterNode build(BuildContext context) => builder(context);
}
