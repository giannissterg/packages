import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_kv/vaster_kv.dart';

/// Conformance suite for `docs/specs/KV_STATE_IMAGE.md` (v1). The golden
/// fixture is the cross-language anchor: an implementation in any
/// language must produce and parse these exact bytes.
void main() {
  // Deterministic fixture exercising both padding runs (9-byte
  // fingerprint → 3 pad bytes to align4; 3 tokens → 4 pad bytes to
  // align8) and a token id above one byte (32000).
  const goldenFingerprint = 'fp-golden';
  const goldenTokens = [1, 2, 32000];
  const goldenState = [0xDE, 0xAD, 0xBE, 0xEF, 0x42];
  final goldenTag = KvStateImage.engineTagOf('vaster-golden');
  const goldenHex = '49564b56010000000000000003000000'
      'be8c026bef6a7a4e0500000000000000'
      '0900000066702d676f6c64656e000000'
      '0100000002000000007d000000000000'
      'deadbeef42';

  Uint8List buildGolden() {
    final bytes = Uint8List(const KvStateImageCodec().layoutSize(
        contentFingerprint: goldenFingerprint,
        tokenCount: goldenTokens.length,
        stateSize: goldenState.length));
    const KvStateImageCodec().initialize(bytes,
            tokenIds: goldenTokens,
            contentFingerprint: goldenFingerprint,
            engineTag: goldenTag,
            stateSize: goldenState.length)
        .stateBytes
        .setAll(0, goldenState);
    return bytes;
  }

  String hexOf(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List goldenFromHex() {
    const clean = goldenHex;
    return Uint8List.fromList([
      for (var i = 0; i < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ]);
  }

  group('golden fixture (cross-language conformance anchor)', () {
    test('producing yields the committed bytes exactly', () {
      expect(hexOf(buildGolden()), goldenHex);
    });

    test('parsing the committed bytes recovers every field', () {
      final image = const KvStateImageCodec().parse(goldenFromHex());
      expect(image.version, 1);
      expect(image.flags, 0);
      expect(image.tokenCount, 3);
      expect(image.engineTag, goldenTag);
      expect(image.contentFingerprint, goldenFingerprint);
      expect(image.tokenIds, goldenTokens);
      expect(image.stateSize, goldenState.length);
      expect(image.stateBytes, goldenState);
      expect(image.stateOffset, 64);
      expect(image.lengthInBytes, 69);
    });

    test('engineTagOf is stable FNV-1a 64', () {
      expect(goldenTag, isNot(0));
      expect(KvStateImage.engineTagOf('vaster-golden'), goldenTag);
      expect(KvStateImage.engineTagOf('vaster-golden2'), isNot(goldenTag));
    });
  });

  group('round trip', () {
    test('empty state, empty tokens, empty fingerprint', () {
      final bytes = Uint8List(const KvStateImageCodec().layoutSize(
          contentFingerprint: '', tokenCount: 0, stateSize: 0));
      final image = const KvStateImageCodec().initialize(bytes,
          tokenIds: const [],
          contentFingerprint: '',
          engineTag: 7,
          stateSize: 0);
      expect(image.tokenIds, isEmpty);
      expect(image.stateBytes, isEmpty);
      expect(image.lengthInBytes, 40, reason: '36 header → align8 = 40');
    });

    test('multibyte UTF-8 fingerprint survives', () {
      const fp = 'sha256:αβγ-ΔΕΖ';
      final bytes = Uint8List(const KvStateImageCodec().layoutSize(
          contentFingerprint: fp, tokenCount: 2, stateSize: 3));
      final image = const KvStateImageCodec().initialize(bytes,
          tokenIds: const [5, 6],
          contentFingerprint: fp,
          engineTag: 1,
          stateSize: 3);
      expect(image.contentFingerprint, fp);
      expect(const KvStateImageCodec().parse(bytes).contentFingerprint, fp);
    });

    test('state section alignment holds across fingerprint/token sizes', () {
      for (final fpLen in [0, 1, 3, 4, 7, 8, 31, 64]) {
        for (final n in [0, 1, 2, 3, 5, 129]) {
          final fp = 'x' * fpLen;
          final bytes = Uint8List(const KvStateImageCodec().layoutSize(
              contentFingerprint: fp, tokenCount: n, stateSize: 1));
          final image = const KvStateImageCodec().initialize(bytes,
              tokenIds: List<int>.generate(n, (i) => i - 2),
              contentFingerprint: fp,
              engineTag: 3,
              stateSize: 1);
          expect(image.stateOffset % 8, 0,
              reason: 'state must be 8-aligned (fp=$fpLen, n=$n)');
          expect(image.tokenIds, List<int>.generate(n, (i) => i - 2),
              reason: 'negative-capable i32 ids round-trip');
        }
      }
    });

    test('views are zero-copy: writing through them mutates the buffer',
        () {
      final bytes = buildGolden();
      final image = const KvStateImageCodec().parse(bytes);
      image.stateBytes[0] = 0x11;
      expect(const KvStateImageCodec().parse(bytes).stateBytes[0], 0x11,
          reason: 'stateBytes is a view over the same memory');
      image.tokenIds[0] = 42;
      expect(const KvStateImageCodec().parse(bytes).tokenIds[0], 42,
          reason: 'tokenIds is a view over the same memory');
    });
  });

  group('validation (spec §Consuming, steps 1–3)', () {
    test('bad magic names both values and suspects pre-format frames', () {
      final bytes = buildGolden()..[0] = 0x00;
      expect(
          () => const KvStateImageCodec().parse(bytes),
          throwsA(isA<KvStateImageFormatException>().having(
              (e) => e.message, 'message', contains('pre-format'))));
    });

    test('unknown version rejected', () {
      final bytes = buildGolden()..[4] = 2;
      expect(() => const KvStateImageCodec().parse(bytes),
          throwsA(isA<KvStateImageFormatException>()));
    });

    test('unknown flags rejected — v1 forward-compat discipline', () {
      final bytes = buildGolden()..[8] = 1;
      expect(
          () => const KvStateImageCodec().parse(bytes),
          throwsA(isA<KvStateImageFormatException>()
              .having((e) => e.message, 'message', contains('flags'))));
    });

    test('every truncation point is caught', () {
      final golden = buildGolden();
      for (final cut in [0, 4, 35, 36, 45, 47, 48, 60, 63, 64, 68]) {
        expect(() => const KvStateImageCodec().parse(Uint8List.sublistView(golden, 0, cut)),
            throwsA(isA<KvStateImageFormatException>()),
            reason: 'a $cut-byte buffer must be rejected as truncated');
      }
      // The exact length parses.
      expect(const KvStateImageCodec().parse(Uint8List.sublistView(golden, 0, 69)),
          isA<KvStateImage>());
    });

    test('trailing container bytes are ignored per spec', () {
      final padded = Uint8List(100)..setAll(0, buildGolden());
      final image = const KvStateImageCodec().parse(padded);
      expect(image.lengthInBytes, 69);
      expect(image.stateBytes, goldenState);
    });

    test('non-zero padding is corruption', () {
      final fpPad = buildGolden()..[45] = 1; // inside fingerprint padding
      expect(
          () => const KvStateImageCodec().parse(fpPad),
          throwsA(isA<KvStateImageFormatException>().having(
              (e) => e.message, 'message', contains('fingerprint padding'))));
      final tokPad = buildGolden()..[62] = 1; // inside token padding
      expect(
          () => const KvStateImageCodec().parse(tokPad),
          throwsA(isA<KvStateImageFormatException>()
              .having((e) => e.message, 'message', contains('token padding'))));
    });

    test('misaligned container base is a typed container bug', () {
      final backing = Uint8List(80);
      final misaligned = Uint8List.sublistView(backing, 4);
      expect(() => const KvStateImageCodec().parse(misaligned),
          throwsA(isA<KvStateImageAlignmentException>()));
      expect(
          () => const KvStateImageCodec().initialize(misaligned,
              tokenIds: const [1],
              contentFingerprint: 'x',
              engineTag: 1,
              stateSize: 1),
          throwsA(isA<KvStateImageAlignmentException>()));
    });

    test('undersized producer buffer is an ArgumentError, not corruption',
        () {
      expect(
          () => const KvStateImageCodec().initialize(Uint8List(10),
              tokenIds: const [1, 2],
              contentFingerprint: 'fp',
              engineTag: 1,
              stateSize: 100),
          throwsArgumentError);
    });
  });

  group('prefixDivergence (spec §Consuming, step 5)', () {
    late KvStateImage image;
    setUp(() => image = const KvStateImageCodec().parse(buildGolden()));

    test('exact prefix permits reuse (-1)', () {
      expect(image.prefixDivergence([1, 2, 32000]), -1);
      expect(image.prefixDivergence([1, 2, 32000, 9, 9]), -1,
          reason: 'a longer prompt still starts with the prefix');
    });

    test('divergence index is the first mismatch', () {
      expect(image.prefixDivergence([1, 7, 32000]), 1);
      expect(image.prefixDivergence([9, 2, 32000]), 0);
      expect(image.prefixDivergence([1, 2, 3]), 2);
    });

    test('a prompt shorter than the prefix diverges at its end', () {
      expect(image.prefixDivergence([1, 2]), 2);
      expect(image.prefixDivergence(const []), 0);
    });

    test('an empty prefix is a prefix of anything', () {
      final bytes = Uint8List(const KvStateImageCodec().layoutSize(
          contentFingerprint: 'e', tokenCount: 0, stateSize: 0));
      final empty = const KvStateImageCodec().initialize(bytes,
          tokenIds: const [],
          contentFingerprint: 'e',
          engineTag: 1,
          stateSize: 0);
      expect(empty.prefixDivergence(const [1, 2]), -1);
      expect(empty.prefixDivergence(const []), -1);
    });
  });

}
