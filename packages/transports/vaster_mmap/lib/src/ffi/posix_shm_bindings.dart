import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// POSIX open flags. O_RDWR is 0x2 everywhere, but the creation flags DIFFER
// per platform — Darwin's O_CREAT (0x0200) is Linux's O_APPEND-adjacent
// territory, and using the wrong value silently creates nothing. Resolve at
// runtime from the actual host.
const int oRdcwr = 0x0002;
final int oCreat = Platform.isMacOS ? 0x0200 : 0x40;
final int oExcl = Platform.isMacOS ? 0x0800 : 0x80;

const int protRead = 0x01;
const int protWrite = 0x02;
const int mapShared = 0x0001;

/// rw-rw-rw- permissions. Dart has no octal literals — a `0666` literal is
/// DECIMAL 666 (= 0o1232: owner write-only!), which creates segments the
/// owner cannot re-open for reading. Always use this constant for mode.
const int mode0666 = 0x1B6; // 0o666
final Pointer<Void> mapFailed = Pointer.fromAddress(-1);

// C Function Signatures
//
// NOTE: `shm_open` and `open` are C *variadic* functions — `mode` is a
// vararg, not a third fixed parameter. On ARM64 (Apple Silicon) variadic
// arguments are passed on the stack, so declaring `mode` as a fixed register
// argument corrupts it (segments get created with garbage permission bits and
// later re-opens fail nondeterministically). `VarArgs` emits the correct ABI.
typedef NativeShmOpen = Int32 Function(
    Pointer<Utf8> name, Int32 oflag, VarArgs<(Int32,)>);
typedef DartShmOpen = int Function(Pointer<Utf8> name, int oflag, int mode);

typedef NativeOpen = Int32 Function(
    Pointer<Utf8> path, Int32 oflag, VarArgs<(Int32,)>);
typedef DartOpen = int Function(Pointer<Utf8> path, int oflag, int mode);

typedef NativeShmUnlink = Int32 Function(Pointer<Utf8> name);
typedef DartShmUnlink = int Function(Pointer<Utf8> name);

typedef NativeClose = Int32 Function(Int32 fd);
typedef DartClose = int Function(int fd);

typedef NativeFtruncate = Int32 Function(Int32 fd, Int64 length);
typedef DartFtruncate = int Function(int fd, int length);

typedef NativeMmap = Pointer<Void> Function(Pointer<Void> addr, Size len, Int32 prot, Int32 flags, Int32 fd, Int64 offset);
typedef DartMmap = Pointer<Void> Function(Pointer<Void> addr, int len, int prot, int flags, int fd, int offset);

typedef NativeMunmap = Int32 Function(Pointer<Void> addr, Size len);
typedef DartMunmap = int Function(Pointer<Void> addr, int len);

/// FFI Bindings helper to low-level POSIX shared memory APIs.
class PosixShmBindings {
  static final DynamicLibrary _libc = DynamicLibrary.process();

  static final DartShmOpen shmOpen = _libc.lookupFunction<NativeShmOpen, DartShmOpen>('shm_open');
  static final DartOpen open = _libc.lookupFunction<NativeOpen, DartOpen>('open');
  static final DartShmUnlink shmUnlink = _libc.lookupFunction<NativeShmUnlink, DartShmUnlink>('shm_unlink');
  static final DartClose close = _libc.lookupFunction<NativeClose, DartClose>('close');
  static final DartFtruncate ftruncate = _libc.lookupFunction<NativeFtruncate, DartFtruncate>('ftruncate');
  static final DartMmap mmap = _libc.lookupFunction<NativeMmap, DartMmap>('mmap');
  static final DartMunmap munmap = _libc.lookupFunction<NativeMunmap, DartMunmap>('munmap');
}
