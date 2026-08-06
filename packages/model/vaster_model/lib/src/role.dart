/// Roles associated with conversation participants in the LLM execution runtime.
enum Role {
  /// System instruction specifying top-level behavior.
  system,

  /// User input.
  user,

  /// Model / assistant output.
  model,

  /// Tool / function execution result output.
  tool,
}
