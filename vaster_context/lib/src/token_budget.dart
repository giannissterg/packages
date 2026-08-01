import 'dart:math';

/// Defines token limit constraints for virtual context compilation.
class TokenBudget {
  /// Maximum context token capacity of the targeted model (e.g. 128,000).
  final int maxContextTokens;

  /// Reserved tokens for candidate model output generation (e.g. 4,096).
  final int reservedOutputTokens;

  /// Reserved tokens for tool definitions and schema declarations.
  final int reservedToolTokens;

  const TokenBudget({
    this.maxContextTokens = 128000,
    this.reservedOutputTokens = 4096,
    this.reservedToolTokens = 1000,
  });

  /// The available token budget remaining for input context messages.
  int get availableInputBudget => max(
        0,
        maxContextTokens - reservedOutputTokens - reservedToolTokens,
      );

  TokenBudget copyWith({
    int? maxContextTokens,
    int? reservedOutputTokens,
    int? reservedToolTokens,
  }) {
    return TokenBudget(
      maxContextTokens: maxContextTokens ?? this.maxContextTokens,
      reservedOutputTokens: reservedOutputTokens ?? this.reservedOutputTokens,
      reservedToolTokens: reservedToolTokens ?? this.reservedToolTokens,
    );
  }

  @override
  String toString() =>
      'TokenBudget(max: $maxContextTokens, inputBudget: $availableInputBudget, outputReserved: $reservedOutputTokens, toolReserved: $reservedToolTokens)';
}
