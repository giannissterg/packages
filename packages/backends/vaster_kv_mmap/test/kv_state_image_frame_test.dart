import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

/// Integration of the container-agnostic KV State Image (vaster_kv) with
/// its shm container (vaster_mmap) — exactly this package's charter.
void main() {
  const goldenFingerprint = 'fp-golden';
  const goldenTokens = [1, 2, 32000];
  const goldenState = [0xDE, 0xAD, 0xBE, 0xEF, 0x42];
  final goldenTag = KvStateImage.engineTagOf('vaster-golden');
  const goldenHex =
      '49564b56010000000000000003000000'
      'be8c026bef6a7a4e0500000000000000'
      '0900000066702d676f6c64656e000000'
      '0100000002000000007d000000000000'
      'deadbeef42';

  String hexOf(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  group('frame integration — the image in its shm container', () {
    test('image written into frame pages parses from a fresh attachment', () {
      final name = 'vaster_kvi_test_${DateTime.now().microsecondsSinceEpoch}';
      final size = const KvStateImageCodec().layoutSize(
        contentFingerprint: goldenFingerprint,
        tokenCount: goldenTokens.length,
        stateSize: goldenState.length,
      );
      final frame = SharedMemoryFrame.allocate(name, payloadLength: size, meta: goldenTokens.length);
      addTearDown(() => frame.close(unlink: true));

      const KvStateImageCodec()
          .initialize(
            frame.bytes,
            tokenIds: goldenTokens,
            contentFingerprint: goldenFingerprint,
            engineTag: goldenTag,
            stateSize: goldenState.length,
          )
          .stateBytes
          .setAll(0, goldenState);

      final attachment = SharedMemoryFrame.attach(name);
      addTearDown(attachment.close);
      final image = const KvStateImageCodec().parse(attachment.bytes);
      expect(
        hexOf(Uint8List.sublistView(attachment.bytes, 0, image.lengthInBytes)),
        goldenHex,
        reason: 'byte-identical through the shared pages',
      );
      expect(image.prefixDivergence([1, 2, 32000, 5]), -1);
    });
  });
}
