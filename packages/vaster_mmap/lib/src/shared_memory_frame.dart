import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'ffi/posix_shm_bindings.dart';

/// Structure layout of a shared-memory frame header.
base class FrameHeader extends Struct {
  @Uint32()
  external int magic; // 0x564B5646 ("VKVF")

  @Uint32()
  external int payloadLength;

  @Uint32()
  external int meta; // caller-defined (e.g. token count of a KV frame)
}

const int frameMagic = 0x564B5646; // "VKVF" — Vaster KV Frame

/// A named POSIX shared-memory **blob segment** holding a single immutable
/// payload — the physical-frame primitive underneath zero-copy KV state
/// sharing.
///
/// Unlike [SharedMemoryRing] (a message-passing ring), a frame is
/// content-at-rest: one process [create]s it, any process that knows the name
/// can [attach] and read the payload through a zero-copy [bytes] view over
/// the same physical pages. Falls back to an mmap'd temp file where
/// `shm_open` is restricted.
class SharedMemoryFrame {
  final String name;
  final int payloadLength;

  /// Caller-defined metadata word stored in the header.
  final int meta;

  final Pointer<Uint8> _basePtr;
  final int _totalSize;
  final File? _fallbackFile;

  SharedMemoryFrame._(
    this.name,
    this.payloadLength,
    this.meta,
    this._basePtr,
    this._totalSize,
    this._fallbackFile,
  );

  static String _cleanName(String name) => name.startsWith('/') ? name : '/$name';

  static String _fallbackPath(String name) =>
      '${Directory.systemTemp.path}/${name.replaceAll('/', '_')}.shm';

  /// Creates (or overwrites) the named frame and copies [payload] into it.
  static SharedMemoryFrame create(String name, Uint8List payload, {int meta = 0}) {
    final cName = _cleanName(name).toNativeUtf8();
    int fd = -1;
    File? fallback;
    try {
      fd = PosixShmBindings.shmOpen(cName, oRdcwr | oCreat, mode0666);
    } catch (_) {}
    if (fd < 0) {
      final path = _fallbackPath(name);
      fallback = File(path)..createSync(recursive: true);
      final cPath = path.toNativeUtf8();
      fd = PosixShmBindings.open(cPath, oRdcwr | oCreat, mode0666);
      calloc.free(cPath);
    }
    calloc.free(cName);
    if (fd < 0) throw StateError('Cannot create shared memory frame "$name".');

    final totalSize = sizeOf<FrameHeader>() + payload.length;
    PosixShmBindings.ftruncate(fd, totalSize);

    final rawPtr = PosixShmBindings.mmap(
        nullptr, totalSize, protRead | protWrite, mapShared, fd, 0);
    // The mapping outlives the descriptor — close it now, success or not.
    PosixShmBindings.close(fd);
    if (rawPtr == mapFailed) {
      throw StateError('Failed mmap for frame "$name".');
    }

    final basePtr = rawPtr.cast<Uint8>();
    final header = rawPtr.cast<FrameHeader>();
    header.ref
      ..magic = frameMagic
      ..payloadLength = payload.length
      ..meta = meta;

    final payloadPtr =
        Pointer<Uint8>.fromAddress(basePtr.address + sizeOf<FrameHeader>());
    payloadPtr.asTypedList(payload.length).setRange(0, payload.length, payload);

    return SharedMemoryFrame._(
        name, payload.length, meta, basePtr, totalSize, fallback);
  }

  /// Attaches to an existing named frame. Throws [StateError] if the segment
  /// does not exist or does not carry a valid frame header.
  static SharedMemoryFrame attach(String name) {
    final cName = _cleanName(name).toNativeUtf8();
    int fd = -1;
    File? fallback;
    try {
      fd = PosixShmBindings.shmOpen(cName, oRdcwr, mode0666); // no O_CREAT
    } catch (_) {}
    if (fd < 0) {
      final path = _fallbackPath(name);
      final file = File(path);
      if (!file.existsSync()) {
        calloc.free(cName);
        throw StateError('Shared memory frame "$name" does not exist.');
      }
      fallback = file;
      final cPath = path.toNativeUtf8();
      fd = PosixShmBindings.open(cPath, oRdcwr, mode0666);
      calloc.free(cPath);
    }
    calloc.free(cName);
    if (fd < 0) throw StateError('Cannot attach shared memory frame "$name".');

    // Map the header first to learn the payload size, then remap in full.
    final headerSize = sizeOf<FrameHeader>();
    final headerPtr = PosixShmBindings.mmap(
        nullptr, headerSize, protRead | protWrite, mapShared, fd, 0);
    if (headerPtr == mapFailed) {
      PosixShmBindings.close(fd);
      throw StateError('Failed header mmap for frame "$name".');
    }
    final header = headerPtr.cast<FrameHeader>().ref;
    if (header.magic != frameMagic) {
      PosixShmBindings.munmap(headerPtr, headerSize);
      PosixShmBindings.close(fd);
      throw StateError('Segment "$name" is not a Vaster frame.');
    }
    final payloadLength = header.payloadLength;
    final meta = header.meta;
    PosixShmBindings.munmap(headerPtr, headerSize);

    final totalSize = headerSize + payloadLength;
    final rawPtr = PosixShmBindings.mmap(
        nullptr, totalSize, protRead | protWrite, mapShared, fd, 0);
    // Full mapping established (or failed) — the descriptor is done either way.
    PosixShmBindings.close(fd);
    if (rawPtr == mapFailed) {
      throw StateError('Failed mmap for frame "$name".');
    }

    return SharedMemoryFrame._(
        name, payloadLength, meta, rawPtr.cast<Uint8>(), totalSize, fallback);
  }

  /// Zero-copy view of the payload — backed directly by the shared pages.
  Uint8List get bytes =>
      Pointer<Uint8>.fromAddress(_basePtr.address + sizeOf<FrameHeader>())
          .asTypedList(payloadLength);

  /// Unmaps the frame; with [unlink] the underlying segment is destroyed.
  void close({bool unlink = false}) {
    PosixShmBindings.munmap(_basePtr.cast<Void>(), _totalSize);
    if (unlink) {
      final cName = _cleanName(name).toNativeUtf8();
      try {
        PosixShmBindings.shmUnlink(cName);
      } catch (_) {}
      calloc.free(cName);
      final fallback = _fallbackFile ?? File(_fallbackPath(name));
      if (fallback.existsSync()) {
        try {
          fallback.deleteSync();
        } catch (_) {}
      }
    }
  }
}
