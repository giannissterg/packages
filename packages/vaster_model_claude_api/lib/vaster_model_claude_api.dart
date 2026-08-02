/// Compiler-level Claude Messages API backend for the VasterModel interface.
///
/// Unlike CLI/text transports, this backend preserves the full typed contract:
/// tool calls round-trip as structured blocks (a real ABI), `responseSchema`
/// lowers to structured outputs, `ContextCacheHint`s lower to `cache_control`
/// breakpoints, and budgets are charged from exact server-reported token usage.
library;

export 'src/claude_api_vaster_model.dart';
