import 'dart:convert';
import 'dart:typed_data';

/// Magic word of a KV state image: "VKVI".
const int kvStateImageMagic = 0x564B5649;

/// Current (and only) layout version — see `docs/specs/KV_STATE_IMAGE.md`.
const int kvStateImageVersion = 1;

/// A KV state image is structurally invalid — wrong magic, unknown
/// version or flags, truncated sections, or non-zero padding. The
/// message names the exact violation and offset where applicable.
final class KvStateImageFormatException implements Exception {
  final String message;
  const KvStateImageFormatException(this.message);
  @override
  String toString() => 'KvStateImageFormatException: $message';
}

/// The container handed the codec a misaligned base. The spec requires
/// an 8-byte-aligned image base (token and state sections depend on
/// it); this is a container bug, never silently repaired with copies.
final class KvStateImageAlignmentException implements Exception {
  final String message;
  const KvStateImageAlignmentException(this.message);
  @override
  String toString() => 'KvStateImageAlignmentException: $message';
}

/// The **KV State Image** codec — reference implementation of
/// `docs/specs/KV_STATE_IMAGE.md` (v1).
///
/// An image is an inference engine's exported sequence state plus the
/// provenance needed to reuse it safely: the exact token ids decoded
/// into the state, the producer's [engineTag], and the source-content
/// fingerprint. The format is language-agnostic and container-agnostic;
/// in Vaster it lives in a `SharedMemoryFrame` payload.
///
/// The codec is **zero-copy by construction**: [parse] validates the
/// header and section bounds, then every accessor is a typed view over
/// the same buffer — [tokenIds] is an `Int32List` view, [stateBytes] a
/// `Uint8List` view, and [stateOffset] supports the pointer-arithmetic
/// path where an engine writes/reads state directly in mapped pages.
/// No section is ever staged through a heap copy. Pure `dart:typed_data`
/// — no FFI — so it is unit-testable like `RingBuffer` and portable to
/// any host the spec targets.
///
/// Validation order follows the spec exactly (magic → version → flags →
/// bounds → padding), and nothing beyond the fixed header is read until
/// the bounds it implies have been proven — the same
/// validate-before-payload discipline as every segment protocol here
/// (rules.md Rule 9).
final class KvStateImage {
  final Uint8List _bytes;
  final ByteData _data;

  /// Number of token ids in the image — the decoded-prefix length.
  final int tokenCount;

  /// Byte length of the opaque engine-state section.
  final int stateSize;

  final int _fingerprintLength;

  KvStateImage._(this._bytes, this._data, this._fingerprintLength,
      {required this.tokenCount, required this.stateSize});

  // ── Layout arithmetic (spec §Layout) ────────────────────────────────

  static const int _fixedHeaderSize = 36;

  static int _align4(int offset) => (offset + 3) & ~3;
  static int _align8(int offset) => (offset + 7) & ~7;

  static int _tokenOffset(int fingerprintLength) =>
      _align4(_fixedHeaderSize + fingerprintLength);

  static int _stateOffset(int fingerprintLength, int tokenCount) =>
      _align8(_tokenOffset(fingerprintLength) + 4 * tokenCount);

  /// Total image length for the given dimensions — what a producer must
  /// allocate (e.g. as a frame's payload size) before [initialize].
  static int layoutSize({
    required String contentFingerprint,
    required int tokenCount,
    required int stateSize,
  }) {
    RangeError.checkNotNegative(tokenCount, 'tokenCount');
    RangeError.checkNotNegative(stateSize, 'stateSize');
    return _stateOffset(utf8.encode(contentFingerprint).length, tokenCount) +
        stateSize;
  }

  // ── Producing ───────────────────────────────────────────────────────

  /// Writes the header, fingerprint, token ids, and zero padding into
  /// [bytes] (which must be at least [layoutSize] long at an 8-aligned
  /// base), leaving the state section for the producer to fill — in the
  /// zero-copy path the engine writes it in place at [stateOffset].
  ///
  /// Returns the image parsed back from the buffer it just wrote:
  /// writer conformance is enforced on every call, not assumed.
  static KvStateImage initialize(
    Uint8List bytes, {
    required List<int> tokenIds,
    required String contentFingerprint,
    required int engineTag,
    required int stateSize,
  }) {
    final fingerprint = utf8.encode(contentFingerprint);
    final tokenOffset = _tokenOffset(fingerprint.length);
    final stateOffset = _stateOffset(fingerprint.length, tokenIds.length);
    final total = stateOffset + stateSize;

    _checkAlignment(bytes);
    if (bytes.length < total) {
      throw ArgumentError('buffer holds ${bytes.length} bytes; the image '
          'needs $total (${tokenIds.length} tokens, '
          '${fingerprint.length}-byte fingerprint, $stateSize state bytes).');
    }

    final data =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, stateOffset);
    data
      ..setUint32(0, kvStateImageMagic, Endian.little)
      ..setUint32(4, kvStateImageVersion, Endian.little)
      ..setUint32(8, 0, Endian.little) // flags: MUST be 0 in v1
      ..setUint32(12, tokenIds.length, Endian.little)
      ..setUint64(16, engineTag, Endian.little)
      ..setUint64(24, stateSize, Endian.little)
      ..setUint32(32, fingerprint.length, Endian.little);
    bytes.setRange(_fixedHeaderSize, _fixedHeaderSize + fingerprint.length,
        fingerprint);
    bytes.fillRange(_fixedHeaderSize + fingerprint.length, tokenOffset, 0);
    Int32List.view(bytes.buffer, bytes.offsetInBytes + tokenOffset,
            tokenIds.length)
        .setAll(0, tokenIds);
    bytes.fillRange(tokenOffset + 4 * tokenIds.length, stateOffset, 0);

    return KvStateImage.parse(bytes);
  }

  // ── Consuming ───────────────────────────────────────────────────────

  /// Parses and fully validates an image (spec §Consuming, steps 1–3):
  /// magic, version, flags, section bounds against the buffer, and
  /// zero padding. Throws typed exceptions; on success every accessor
  /// is a zero-copy view. The [engineTag] comparison and token-exact
  /// prefix validation (steps 4–5) are the consumer's next moves —
  /// [prefixDivergence] implements step 5's check.
  factory KvStateImage.parse(Uint8List bytes) {
    _checkAlignment(bytes);
    if (bytes.length < _fixedHeaderSize) {
      throw KvStateImageFormatException(
          'truncated: ${bytes.length} bytes cannot hold the '
          '$_fixedHeaderSize-byte fixed header.');
    }
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes,
        bytes.length);

    final magic = data.getUint32(0, Endian.little);
    if (magic != kvStateImageMagic) {
      throw KvStateImageFormatException('bad magic '
          '0x${magic.toRadixString(16)} (expected "VKVI" '
          '0x${kvStateImageMagic.toRadixString(16)}) — not a KV state '
          'image, or a pre-format frame.');
    }
    final version = data.getUint32(4, Endian.little);
    if (version != kvStateImageVersion) {
      throw KvStateImageFormatException('unsupported version $version '
          '(this reader implements v$kvStateImageVersion).');
    }
    final flags = data.getUint32(8, Endian.little);
    if (flags != 0) {
      throw KvStateImageFormatException('unknown flags '
          '0x${flags.toRadixString(16)} — v1 readers reject flags they '
          'do not understand.');
    }

    final tokenCount = data.getUint32(12, Endian.little);
    final stateSize = data.getUint64(24, Endian.little);
    final fingerprintLength = data.getUint32(32, Endian.little);

    final tokenOffset = _tokenOffset(fingerprintLength);
    final stateOffset = _stateOffset(fingerprintLength, tokenCount);
    final total = stateOffset + stateSize;
    if (bytes.length < total) {
      throw KvStateImageFormatException(
          'truncated: header declares $tokenCount tokens, '
          '$fingerprintLength-byte fingerprint, $stateSize state bytes '
          '($total total) but the buffer holds ${bytes.length}.');
    }

    for (var i = _fixedHeaderSize + fingerprintLength; i < tokenOffset; i++) {
      if (bytes[i] != 0) {
        throw KvStateImageFormatException(
            'non-zero fingerprint padding at offset $i — corrupt image '
            'or non-conformant writer.');
      }
    }
    for (var i = tokenOffset + 4 * tokenCount; i < stateOffset; i++) {
      if (bytes[i] != 0) {
        throw KvStateImageFormatException(
            'non-zero token padding at offset $i — corrupt image or '
            'non-conformant writer.');
      }
    }

    return KvStateImage._(bytes, data, fingerprintLength,
        tokenCount: tokenCount, stateSize: stateSize);
  }

  static void _checkAlignment(Uint8List bytes) {
    if (bytes.offsetInBytes % 8 != 0) {
      throw KvStateImageAlignmentException(
          'image base at buffer offset ${bytes.offsetInBytes} is not '
          '8-byte aligned — the container must present an aligned '
          'payload (spec §Layout).');
    }
  }

  // ── Accessors — every one a zero-copy view ─────────────────────────

  /// Layout version of this image.
  int get version => _data.getUint32(4, Endian.little);

  /// Reserved flag word (always 0 in v1).
  int get flags => _data.getUint32(8, Endian.little);

  /// Opaque 64-bit producer identity — compare for equality only
  /// (spec §engineTag). A mismatch forbids restoring [stateBytes].
  int get engineTag => _data.getUint64(16, Endian.little);

  /// Fingerprint of the source content this state was derived from.
  String get contentFingerprint => utf8.decode(Uint8List.view(_bytes.buffer,
      _bytes.offsetInBytes + _fixedHeaderSize, _fingerprintLength));

  /// The decoded-prefix token ids — a zero-copy `Int32List` view over
  /// the image (host-endian view; correct on all supported LE hosts,
  /// see spec §Endianness).
  Int32List get tokenIds => Int32List.view(_bytes.buffer,
      _bytes.offsetInBytes + _tokenOffset(_fingerprintLength), tokenCount);

  /// Byte offset of the state section within the image — the
  /// pointer-arithmetic path: an engine reads/writes state at
  /// `payloadPointer + stateOffset`, never staging through the heap.
  int get stateOffset => _stateOffset(_fingerprintLength, tokenCount);

  /// The opaque engine-state section as a zero-copy view.
  Uint8List get stateBytes => Uint8List.view(
      _bytes.buffer, _bytes.offsetInBytes + stateOffset, stateSize);

  /// Total image length in bytes (trailing container bytes are ignored
  /// per spec).
  int get lengthInBytes => stateOffset + stateSize;

  // ── Reuse semantics helpers ────────────────────────────────────────

  /// Spec §Consuming step 5: token-exact prefix validation. Returns the
  /// index of the first divergence between [tokenIds] and the leading
  /// tokens of [promptTokens] — including [promptTokens] being shorter
  /// than the prefix — or `-1` when the image is an exact prefix and
  /// reuse is permitted. The index makes render-contract drift
  /// diagnosable, not just detectable.
  int prefixDivergence(List<int> promptTokens) {
    final prefix = tokenIds;
    for (var i = 0; i < tokenCount; i++) {
      if (i >= promptTokens.length || promptTokens[i] != prefix[i]) {
        return i;
      }
    }
    return -1;
  }

  /// FNV-1a 64 over the UTF-8 of [description] — the reference
  /// [engineTag] derivation. Producers compose the description from
  /// everything that affects state compatibility (engine build, model
  /// identity); consumers only ever compare tags for equality.
  static int engineTagOf(String description) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(description)) {
      hash ^= byte;
      hash *= 0x100000001b3; // wraps in 64-bit VM ints by design
    }
    return hash;
  }
}
