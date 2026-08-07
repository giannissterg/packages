import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

void main() {
  group('TokenEstimate', () {
    test('forText rounds up at ~4 chars/token', () {
      expect(TokenEstimate.forText(''), equals(0));
      expect(TokenEstimate.forText('abcd'), equals(1));
      expect(TokenEstimate.forText('abcde'), equals(2));
      expect(TokenEstimate.forText('x' * 100), equals(25));
    });

    test('forMessages adds per-message overhead', () {
      final messages = [
        ChatMessage.user('x' * 8), // 2 tokens + 4 overhead
        ChatMessage.model('x' * 4), // 1 token + 4 overhead
      ];
      expect(TokenEstimate.forMessages(messages), equals(2 + 4 + 1 + 4));
    });

    test('forExchange is labeled estimated', () {
      final usage = TokenEstimate.forExchange(prompt: 'x' * 40, output: 'y' * 20);
      expect(usage.promptTokenCount, equals(10));
      expect(usage.candidatesTokenCount, equals(5));
      expect(usage.totalTokenCount, equals(15));
      expect(usage.source, equals(UsageSource.estimated));
    });
  });
}
