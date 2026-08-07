import 'dart:async';
import 'dart:convert';

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

    test('MmapVasterModel round-trips a real sidecar answer (duplex rings)', () async {
      // Duplex: request and response travel on separate rings. A single
      // shared ring lets the polling client consume its own request — the
      // race the old fake-success stub used to hide.
      final res = SharedMemoryRing(
          shmName: '/vaster_res_${DateTime.now().microsecondsSinceEpoch}', capacity: 64 * 1024);
      addTearDown(res.close);
      final model = MmapVasterModel(ring: ring, responseRing: res, targetModelName: 'llama-3-8b');
      expect(model.modelName, equals('llama-3-8b'));
      expect(model.descriptor, equals('mmap:llama-3-8b'));

      final request = const ModelRequest(
        systemInstruction:
            ChatMessage(role: Role.system, parts: [TextPart('You are a native C++ model sidecar.')]),
        messages: [
          ChatMessage(role: Role.user, parts: [TextPart('Generate code')])
        ],
      );

      // A minimal sidecar: answer the first request envelope.
      unawaited(Future(() async {
        while (true) {
          final payload = ring.readString();
          if (payload == null) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            continue;
          }
          final envelope = jsonDecode(payload) as Map<String, dynamic>;
          expect(envelope['action'], 'generate');
          res.writeString(jsonEncode(ModelResponse(
            message: ChatMessage.model('int main() { return 0; }'),
          ).toJson()));
          return;
        }
      }));

      final response = await model.generate(request);
      expect(response.text, contains('int main'));
      expect(response.finishReason, equals(FinishReason.stop));
    });

    test('no sidecar → typed SidecarUnavailableException, never fake success', () async {
      final res = SharedMemoryRing(
          shmName: '/vaster_res2_${DateTime.now().microsecondsSinceEpoch}', capacity: 64 * 1024);
      addTearDown(res.close);
      final model = MmapVasterModel(
        ring: ring,
        responseRing: res,
        responseTimeout: const Duration(milliseconds: 60),
      );
      await expectLater(
        model.generate(ModelRequest(messages: [ChatMessage.user('hi')])),
        throwsA(isA<SidecarUnavailableException>()),
      );
      ring.readPacket(); // drain the request we wrote
    });

    test('a sidecar error envelope → typed SidecarRemoteException', () async {
      final res = SharedMemoryRing(
          shmName: '/vaster_res3_${DateTime.now().microsecondsSinceEpoch}', capacity: 64 * 1024);
      addTearDown(res.close);
      final model = MmapVasterModel(ring: ring, responseRing: res);
      unawaited(Future(() async {
        while (ring.readString() == null) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        res.writeString(jsonEncode({'error': 'model exploded'}));
      }));
      await expectLater(
        model.generate(ModelRequest(messages: [ChatMessage.user('hi')])),
        throwsA(isA<SidecarRemoteException>()),
      );
    });

    test('ring ops after close are typed errors, not native faults', () {
      final doomed = SharedMemoryRing(
          shmName: '/vaster_closed_${DateTime.now().microsecondsSinceEpoch}', capacity: 64 * 1024);
      doomed.close();
      expect(doomed.readPacket, throwsStateError);
      expect(() => doomed.writeString('x'), throwsStateError);
    });
  });
}
