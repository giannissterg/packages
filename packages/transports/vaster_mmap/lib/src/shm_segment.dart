import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'ffi/posix_shm_bindings.dart';

/// Lifecycle of one POSIX shared-memory mapping — nothing else.
///
/// This is the composition root of the package: [SharedMemoryRing] and
/// [SharedMemoryFrame] are both thin protocols composed over a segment, not
/// parallel monoliths each carrying their own copy of the open/attach/mmap
/// ladder. The segment fixes the lifecycle bugs that ladder used to have:
/// - **Owner vs attacher is explicit.** `O_EXCL` on the create attempt
///   discovers which one we are; only the owner sizes the segment and only
///   the owner unlinks it by default on [close].
/// - **The fd never leaks.** POSIX keeps a mapping alive after its fd is
///   closed, so the factories close the descriptor immediately after `mmap`
///   — on success *and* on every failure path.
/// - **No `late` fields, no silent catches.** All state is final, assigned by
///   factories that either return a fully-mapped segment or throw after
///   cleaning up exactly what they had opened.
///
/// Falls back to an mmap'd temp file where `shm_open` is restricted
/// (sandboxed test environments) — same ownership semantics.
final class ShmSegment {
  final String name;

  /// Mapped size in bytes.
  final int size;

  /// True when this process created the segment (vs attached to an existing
  /// one). The owner unlinks on [close] by default; attachers never do.
  final bool isOwner;

  /// Base of the mapping.
  final Pointer<Uint8> base;

  final File? _fallbackFile;
  bool _closed = false;

  ShmSegment._({
    required this.name,
    required this.size,
    required this.isOwner,
    required this.base,
    required File? fallbackFile,
  }) : _fallbackFile = fallbackFile;

  static String _posixName(String name) => name.startsWith('/') ? name : '/$name';

  static String _fallbackPath(String name) => '${Directory.systemTemp.path}/${name.replaceAll('/', '_')}.shm';

  /// Opens the named segment, creating it when absent (create-or-attach).
  ///
  /// The create-then-attach ladder makes ownership a fact, not a guess:
  /// 1. `shm_open(O_CREAT|O_EXCL)` — success means we created it (owner).
  /// 2. `shm_open` plain — success means it existed (attacher).
  /// 3. The same two steps against a temp file when shm is unavailable.
  ///
  /// Only the owner `ftruncate`s to [size]; an attacher maps [size] bytes of
  /// the existing segment as-is.
  factory ShmSegment.open({required String name, required int size}) =>
      _map(name: name, size: size, allowCreate: true);

  /// Attaches to an existing segment; throws [StateError] when it does not
  /// exist. Never creates, never becomes owner, never resizes real shm
  /// (the file fallback still grows a stale undersized backing — growing is
  /// always safe, shrinking never happens).
  factory ShmSegment.attach({required String name, required int size}) =>
      _map(name: name, size: size, allowCreate: false);

  static ShmSegment _map({
    required String name,
    required int size,
    required bool allowCreate,
  }) {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be positive');
    }

    final (fd, isOwner, fallbackFile) = _openBacking(name, allowCreate: allowCreate);
    if (fd < 0) {
      throw StateError(allowCreate
          ? 'Cannot open shared memory segment "$name" (shm and file '
              'fallback both failed).'
          : 'Shared memory segment "$name" does not exist.');
    }

    // The owner sizes the segment. An attacher on the FILE fallback also
    // grows an undersized backing (stale short file from a crashed peer):
    // mapping past a file's last page and touching it is SIGBUS, and growing
    // is always safe (zero-fill), unlike shrinking, which is never done.
    final mustSize = isOwner || (fallbackFile != null && fallbackFile.lengthSync() < size);
    if (mustSize && PosixShmBindings.ftruncate(fd, size) != 0) {
      PosixShmBindings.close(fd);
      if (isOwner) _unlinkBacking(name, fallbackFile);
      throw StateError('Cannot size shared memory segment "$name" to $size.');
    }

    final rawPtr = PosixShmBindings.mmap(nullptr, size, protRead | protWrite, mapShared, fd, 0);
    // The mapping outlives the descriptor — close it NOW so nothing leaks,
    // whether mmap succeeded or not.
    PosixShmBindings.close(fd);
    if (rawPtr == mapFailed) {
      if (isOwner) _unlinkBacking(name, fallbackFile);
      throw StateError('Failed mmap on shared memory segment "$name".');
    }

    return ShmSegment._(
      name: name,
      size: size,
      isOwner: isOwner,
      base: rawPtr.cast<Uint8>(),
      fallbackFile: fallbackFile,
    );
  }

  /// One open ladder for both factories. Returns `fd < 0` when the backing
  /// could not be opened under the given create policy.
  static (int, bool, File?) _openBacking(String name, {required bool allowCreate}) {
    var fd = -1;
    var isOwner = false;

    final cName = _posixName(name).toNativeUtf8();
    try {
      if (allowCreate) {
        fd = PosixShmBindings.shmOpen(cName, oRdcwr | oCreat | oExcl, mode0666);
        if (fd >= 0) isOwner = true;
      }
      if (fd < 0) {
        fd = PosixShmBindings.shmOpen(cName, oRdcwr, mode0666);
      }
    } finally {
      calloc.free(cName);
    }
    if (fd >= 0) return (fd, isOwner, null);

    // shm_open unavailable or denied: file-backed mmap with the same
    // exclusive-create ownership discovery.
    final path = _fallbackPath(name);
    final fallbackFile = File(path);
    final cPath = path.toNativeUtf8();
    try {
      if (allowCreate) {
        fd = PosixShmBindings.open(cPath, oRdcwr | oCreat | oExcl, mode0666);
        if (fd >= 0) isOwner = true;
      }
      if (fd < 0) {
        fd = PosixShmBindings.open(cPath, oRdcwr, mode0666);
      }
    } finally {
      calloc.free(cPath);
    }
    return (fd, isOwner, fd >= 0 ? fallbackFile : null);
  }

  /// Typed zero-copy view over [length] bytes of the mapping starting at
  /// byte [offset] — how composed protocols (ring payload region, frame
  /// payload) address their slice of the segment.
  Uint8List view(int offset, int length) {
    RangeError.checkValueInInterval(offset + length, 0, size, 'offset+length');
    return Pointer<Uint8>.fromAddress(base.address + offset).asTypedList(length);
  }

  /// Unmaps the segment. The backing object is unlinked when [unlink] is
  /// true, defaulting to [isOwner]: creators tear down, attachers detach.
  /// Idempotent.
  void close({bool? unlink}) {
    if (_closed) return;
    _closed = true;
    PosixShmBindings.munmap(base.cast<Void>(), size);
    if (unlink ?? isOwner) {
      _unlinkBacking(name, _fallbackFile);
    }
  }

  static void _unlinkBacking(String name, File? fallbackFile) {
    if (fallbackFile != null) {
      try {
        fallbackFile.deleteSync();
      } on FileSystemException {
        // Peer already deleted it — detaching is still complete.
      }
      return;
    }
    final cName = _posixName(name).toNativeUtf8();
    PosixShmBindings.shmUnlink(cName);
    calloc.free(cName);
  }
}
