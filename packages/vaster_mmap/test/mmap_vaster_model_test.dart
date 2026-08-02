import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

void main() {
  group('Zero-Copy POSIX Shared Memory IPC (vaster_mmap)', () {
    late SharedMemoryRing ring;

    setUp(() {
      ring = SharedMemoryRing(
        shmName: '/vaster_test_shm_${DateTime.now().microsecondsSinceEpoch}',
        capacity: 1024 * 1024, // 1MB
      );
    });

    tearDown(() {
      ring.close();
    });

    test('SharedMemoryRing writes and reads binary byte frames with zero copy', () {
      final inputBytes = [65, 66, 67, 68, 69]; // "ABCDE"
      ring.writePacket(inputBytes);

      final readBytes = ring.readPacket();
      expect(readBytes, isNotNull);
      expect(readBytes, equals(inputBytes));
    });

    test('SharedMemoryRing writes and reads UTF-8 text string frames', () {
      const message = 'Hello Vaster Shared Memory Ring Buffer!';
      ring.writeString(message);

      final readText = ring.readString();
      expect(readText, equals(message));
    });

    test('MmapVasterModel generates response over POSIX Shared Memory', () async {
      final model = MmapVasterModel(ring: ring, targetModelName: 'llama-3-8b');
      expect(model.modelName, equals('llama-3-8b'));
      expect(model.descriptor, equals('mmap:llama-3-8b'));

      final request = const ModelRequest(
        systemInstruction: ChatMessage(role: Role.system, parts: [TextPart('You are a native C++ model sidecar.')]),
        messages: [ChatMessage(role: Role.user, parts: [TextPart('Generate code')])],
      );

      final response = await model.generate(request);
      expect(response.text, contains('Zero-copy shared memory frame delivered'));
      expect(response.finishReason, equals(FinishReason.stop));

      final streamChunks = await model.generateStream(request).toList();
      expect(streamChunks, hasLength(1));
      expect(streamChunks.first.textDelta, contains('Zero-copy shared memory frame delivered'));
    });
  });
}
