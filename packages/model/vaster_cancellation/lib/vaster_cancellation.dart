/// Cross-cutting cancellation contract — its own leaf (B3): tools,
/// sandboxes, and models all consume it; none of them should drag the
/// model package in for one token type.
library;

export 'src/cancellation_token.dart';
