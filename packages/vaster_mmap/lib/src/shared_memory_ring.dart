import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'ffi/posix_shm_bindings.dart';

/// Structure layout of the POSIX Shared Memory Header block.
base class ShmHeader extends Struct {
  @Uint32()
  external int magic; // 0x56415354 ("VAST")

  @Uint32()
  external int ringSize; // Total payload capacity (e.g. 4,194,304 bytes)

  @Uint32()
  external int head; // Write offset pointer

  @Uint32()
  external int tail; // Read offset pointer

  @Uint32()
  external int status; // 0 = Idle, 1 = Ready, 2 = Busy
}

const int defaultShmCapacity = 4 * 1024 * 1024; // 4MB Shared RAM Page
const int shmMagic = 0x56415354; // "VAST"

/// High-speed zero-copy Shared Memory Ring Buffer wrapping mapped RAM pages.
class SharedMemoryRing {
  final String shmName;
  final int capacity;
  late final int _fd;
  late final Pointer<Uint8> _basePtr;
  late final Pointer<ShmHeader> _headerPtr;
  late final Pointer<Uint8> _payloadPtr;
  late final File? _fallbackFile;

  SharedMemoryRing({
    required this.shmName,
    this.capacity = defaultShmCapacity,
  }) {
    final cleanName = shmName.startsWith('/') ? shmName : '/$shmName';
    final cName = cleanName.toNativeUtf8();

    int fd = -1;
    File? tempFile;

    try {
      // Try native POSIX shm_open first
      fd = PosixShmBindings.shmOpen(
        cName,
        oRdcwr | oCreat,
        mode0666,
      );
    } catch (_) {}

    // Fallback to POSIX memory-mapped file if shm_open is restricted
    if (fd < 0) {
      final tmpPath = '${Directory.systemTemp.path}/${shmName.replaceAll('/', '_')}.shm';
      tempFile = File(tmpPath);
      if (!tempFile.existsSync()) {
        tempFile.createSync(recursive: true);
      }
      final cPath = tmpPath.toNativeUtf8();
      fd = PosixShmBindings.open(cPath, oRdcwr | oCreat, mode0666);
      calloc.free(cPath);
    }

    _fd = fd;
    _fallbackFile = tempFile;

    final totalSize = sizeOf<ShmHeader>() + capacity;
    PosixShmBindings.ftruncate(_fd, totalSize);

    final rawPtr = PosixShmBindings.mmap(
      nullptr,
      totalSize,
      protRead | protWrite,
      mapShared,
      _fd,
      0,
    );

    if (rawPtr == mapFailed) {
      calloc.free(cName);
      throw StateError('Failed mmap on POSIX segment "$shmName"');
    }

    _basePtr = rawPtr.cast<Uint8>();
    _headerPtr = rawPtr.cast<ShmHeader>();
    _payloadPtr = Pointer.fromAddress(_basePtr.address + sizeOf<ShmHeader>());

    // Initialize header metadata if new segment
    if (_headerPtr.ref.magic != shmMagic) {
      _headerPtr.ref.magic = shmMagic;
      _headerPtr.ref.ringSize = capacity;
      _headerPtr.ref.head = 0;
      _headerPtr.ref.tail = 0;
      _headerPtr.ref.status = 0;
    }

    calloc.free(cName);
  }

  /// Writes a binary payload directly into shared RAM pages with zero-copy header pointers.
  void writePacket(List<int> bytes) {
    final payloadLength = bytes.length;
    if (payloadLength > capacity) {
      throw ArgumentError('Payload size ($payloadLength bytes) exceeds ring capacity ($capacity bytes)');
    }

    final currentHead = _headerPtr.ref.head;
    final view = _payloadPtr.asTypedList(capacity);

    // Write 4-byte payload length prefix
    final lenBytes = ByteData(4)..setUint32(0, payloadLength, Endian.big);
    for (var i = 0; i < 4; i++) {
      view[(currentHead + i) % capacity] = lenBytes.getUint8(i);
    }

    // Write binary payload bytes
    for (var i = 0; i < payloadLength; i++) {
      view[(currentHead + 4 + i) % capacity] = bytes[i];
    }

    _headerPtr.ref.head = (currentHead + 4 + payloadLength) % capacity;
    _headerPtr.ref.status = 1; // Signal Ready
  }

  /// Reads a binary payload frame directly from shared RAM pages.
  Uint8List? readPacket() {
    final currentHead = _headerPtr.ref.head;
    final currentTail = _headerPtr.ref.tail;

    if (currentHead == currentTail) return null; // No data available

    final view = _payloadPtr.asTypedList(capacity);

    // Read 4-byte payload length prefix
    final lenBytes = ByteData(4);
    for (var i = 0; i < 4; i++) {
      lenBytes.setUint8(i, view[(currentTail + i) % capacity]);
    }
    final payloadLength = lenBytes.getUint32(0, Endian.big);

    final payload = Uint8List(payloadLength);
    for (var i = 0; i < payloadLength; i++) {
      payload[i] = view[(currentTail + 4 + i) % capacity];
    }

    _headerPtr.ref.tail = (currentTail + 4 + payloadLength) % capacity;
    return payload;
  }

  /// Writes a UTF-8 text string frame directly to shared RAM pages.
  void writeString(String text) {
    writePacket(utf8.encode(text));
  }

  /// Reads a UTF-8 text string frame directly from shared RAM pages.
  String? readString() {
    final bytes = readPacket();
    if (bytes == null) return null;
    return utf8.decode(bytes);
  }

  /// Closes and unmaps shared memory pointers.
  void close() {
    final totalSize = sizeOf<ShmHeader>() + capacity;
    PosixShmBindings.munmap(_basePtr.cast<Void>(), totalSize);
    final cleanName = shmName.startsWith('/') ? shmName : '/$shmName';
    final cName = cleanName.toNativeUtf8();
    PosixShmBindings.shmUnlink(cName);
    calloc.free(cName);
    final fallback = _fallbackFile;
    if (fallback != null && fallback.existsSync()) {
      try {
        fallback.deleteSync();
      } catch (_) {}
    }
  }
}
