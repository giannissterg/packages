import 'dart:ffi';

import 'shm_segment.dart';

/// The shared identity convention for typed shared-memory segments.
///
/// Every Vaster segment protocol (ring, frame) begins its header with the
/// same two aligned 32-bit words — `magic` then `version` — and this one
/// composable owns stamping and validating them. Protocols compose a tag
/// instead of each re-implementing "is this really ours, and do we speak the
/// same layout?" against raw pointers.
final class SegmentTag {
  /// Protocol identity word (e.g. "VAST" for rings, "VKVF" for frames).
  final int magic;

  /// Header layout version this build speaks.
  final int version;

  /// Human name used in errors ("ring", "frame").
  final String protocol;

  const SegmentTag({
    required this.magic,
    required this.version,
    required this.protocol,
  });

  /// Writes the tag words at the segment base. Owner-side, on creation.
  void stamp(ShmSegment segment) {
    final words = segment.base.cast<Uint32>();
    words[0] = magic;
    words[1] = version;
  }

  /// Validates the tag words at the segment base. Attacher-side, before any
  /// other header field — and before any payload byte — is trusted. Closes
  /// [segment] (without unlinking) and throws [StateError] on mismatch.
  void validate(ShmSegment segment) {
    final words = segment.base.cast<Uint32>();
    final foundMagic = words[0];
    final foundVersion = words[1];
    void fail(String reason) {
      segment.close(unlink: false);
      throw StateError('Segment "${segment.name}" $reason');
    }

    if (foundMagic != magic) {
      fail('is not a Vaster $protocol '
          '(magic 0x${foundMagic.toRadixString(16)}). A stale fallback file '
          'from a crashed peer looks like this — delete it and retry.');
    }
    if (foundVersion != version) {
      fail('uses $protocol layout v$foundVersion; this build speaks '
          'v$version.');
    }
  }
}
