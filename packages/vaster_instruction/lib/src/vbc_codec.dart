import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'vaster_instruction_base.dart';
import 'vaster_program.dart';

/// Thrown when a byte payload is not a valid VBC program.
final class VbcDecodeException implements Exception {
  final String message;
  const VbcDecodeException(this.message);

  @override
  String toString() => 'VbcDecodeException: $message';
}

/// **VBC — Vaster ByteCode**, the binary container format for [VasterProgram].
///
/// ```text
/// ┌────────────────────────────────────────────────────────────┐
/// │ magic   u32  0x56424301 ("VBC" + format 1)                 │
/// │ version u16  container version (currently 1)               │
/// │ flags   u16  reserved (0)                                  │
/// │ sha256  32B  integrity checksum of the payload             │
/// │ payload:                                                   │
/// │   string pool   varint count, then (varint len, utf8)*     │
/// │   program name  varint pool index                          │
/// │   instructions  varint count, then value-encoded op maps   │
/// └────────────────────────────────────────────────────────────┘
/// ```
///
/// Instructions are encoded as **tagged values over their canonical
/// [VasterInstruction.toJson] maps** with all strings deduplicated through
/// the pool. This makes the format *maintenance-free with respect to the
/// ISA*: any opcode that round-trips JSON — including every future one —
/// round-trips VBC with no per-opcode encoder, while typically shrinking to
/// a fraction of the JSON text (repeated keys, register names, and opcode
/// names collapse into 1–2 byte pool references).
///
/// Unlike JSON text, VBC also preserves exact numeric types (int vs double).
///
/// The codec is pure bytes-in/bytes-out — no dart:io — so it works in every
/// runtime, can ride a `SharedMemoryFrame` for zero-copy cross-process
/// program shipping, and leaves file I/O to CLI-level callers.
final class VbcCodec {
  static const int magic = 0x56424301; // "VBC" 0x01
  static const int formatVersion = 1;
  static const int _headerLength = 4 + 2 + 2 + 32;

  // Value tags.
  static const int _tagNull = 0x00;
  static const int _tagFalse = 0x01;
  static const int _tagTrue = 0x02;
  static const int _tagInt = 0x03;
  static const int _tagDouble = 0x04;
  static const int _tagString = 0x05;
  static const int _tagList = 0x06;
  static const int _tagMap = 0x07;

  const VbcCodec();

  // ── Encoding ───────────────────────────────────────────────────────────

  /// Encodes [program] into a VBC byte payload.
  Uint8List encode(VasterProgram program) {
    // Pass 1: build the deduplicating string pool.
    final pool = <String, int>{};
    final poolStrings = <String>[];
    int intern(String value) => pool.putIfAbsent(value, () {
          poolStrings.add(value);
          return poolStrings.length - 1;
        });

    void collectStrings(Object? value) {
      switch (value) {
        case String s:
          intern(s);
        case List l:
          l.forEach(collectStrings);
        case Map m:
          m.forEach((key, entry) {
            intern(key as String);
            collectStrings(entry);
          });
        default:
          break;
      }
    }

    intern(program.programName);
    final instructionMaps =
        program.instructions.map((i) => i.toJson()).toList(growable: false);
    for (final map in instructionMaps) {
      collectStrings(map);
    }

    // Pass 2: emit the payload.
    final payload = BytesBuilder(copy: false);
    _writeVarint(payload, poolStrings.length);
    for (final value in poolStrings) {
      final bytes = utf8.encode(value);
      _writeVarint(payload, bytes.length);
      payload.add(bytes);
    }
    _writeVarint(payload, pool[program.programName]!);
    _writeVarint(payload, instructionMaps.length);
    for (final map in instructionMaps) {
      _writeValue(payload, map, pool);
    }
    final payloadBytes = payload.toBytes();

    // Container: header + checksum + payload.
    final digest = sha256.convert(payloadBytes).bytes;
    final out = BytesBuilder(copy: false);
    final header = ByteData(8)
      ..setUint32(0, magic, Endian.big)
      ..setUint16(4, formatVersion, Endian.big)
      ..setUint16(6, 0, Endian.big); // flags
    out
      ..add(header.buffer.asUint8List())
      ..add(digest)
      ..add(payloadBytes);
    return out.toBytes();
  }

  void _writeValue(BytesBuilder out, Object? value, Map<String, int> pool) {
    switch (value) {
      case null:
        out.addByte(_tagNull);
      case bool b:
        out.addByte(b ? _tagTrue : _tagFalse);
      case int i:
        out.addByte(_tagInt);
        _writeVarint(out, _zigzagEncode(i));
      case double d:
        out.addByte(_tagDouble);
        final bytes = ByteData(8)..setFloat64(0, d, Endian.big);
        out.add(bytes.buffer.asUint8List());
      case String s:
        out.addByte(_tagString);
        _writeVarint(out, pool[s]!);
      case List l:
        out.addByte(_tagList);
        _writeVarint(out, l.length);
        for (final entry in l) {
          _writeValue(out, entry, pool);
        }
      case Map m:
        out.addByte(_tagMap);
        _writeVarint(out, m.length);
        m.forEach((key, entry) {
          _writeVarint(out, pool[key as String]!);
          _writeValue(out, entry, pool);
        });
      default:
        throw ArgumentError(
            'VBC cannot encode value of type ${value.runtimeType}');
    }
  }

  // ── Decoding ───────────────────────────────────────────────────────────

  /// Decodes a VBC byte payload back into a [VasterProgram].
  ///
  /// Throws [VbcDecodeException] on bad magic, unsupported version,
  /// checksum mismatch, or truncated/corrupt payloads.
  VasterProgram decode(Uint8List bytes) {
    if (bytes.length < _headerLength) {
      throw const VbcDecodeException('Truncated: shorter than the VBC header.');
    }
    final header = ByteData.sublistView(bytes, 0, 8);
    if (header.getUint32(0, Endian.big) != magic) {
      throw const VbcDecodeException('Bad magic: not a VBC program.');
    }
    final version = header.getUint16(4, Endian.big);
    if (version != formatVersion) {
      throw VbcDecodeException(
          'Unsupported VBC version $version (supported: $formatVersion).');
    }

    final storedDigest = bytes.sublist(8, 40);
    final payload = Uint8List.sublistView(bytes, _headerLength);
    final actualDigest = sha256.convert(payload).bytes;
    for (var i = 0; i < 32; i++) {
      if (storedDigest[i] != actualDigest[i]) {
        throw const VbcDecodeException(
            'Checksum mismatch: payload is corrupt.');
      }
    }

    final reader = _ByteReader(payload);
    try {
      final poolLength = reader.readVarint();
      final poolStrings = List<String>.generate(poolLength, (_) {
        final length = reader.readVarint();
        return utf8.decode(reader.readBytes(length));
      });
      String poolAt(int index) {
        if (index < 0 || index >= poolStrings.length) {
          throw const VbcDecodeException('String pool index out of range.');
        }
        return poolStrings[index];
      }

      final programName = poolAt(reader.readVarint());
      final instructionCount = reader.readVarint();
      final instructions = List<VasterInstruction>.generate(
        instructionCount,
        (_) {
          final value = _readValue(reader, poolAt);
          if (value is! Map<String, dynamic>) {
            throw const VbcDecodeException(
                'Instruction entry is not a map.');
          }
          return VasterInstruction.fromJson(value);
        },
      );

      return VasterProgram(
        programName: programName,
        instructions: instructions,
      );
    } on VbcDecodeException {
      rethrow;
    } catch (e) {
      throw VbcDecodeException('Corrupt payload: $e');
    }
  }

  Object? _readValue(_ByteReader reader, String Function(int) poolAt) {
    final tag = reader.readByte();
    switch (tag) {
      case _tagNull:
        return null;
      case _tagFalse:
        return false;
      case _tagTrue:
        return true;
      case _tagInt:
        return _zigzagDecode(reader.readVarint());
      case _tagDouble:
        return ByteData.sublistView(reader.readBytes(8)).getFloat64(0, Endian.big);
      case _tagString:
        return poolAt(reader.readVarint());
      case _tagList:
        final length = reader.readVarint();
        return List<Object?>.generate(
            length, (_) => _readValue(reader, poolAt));
      case _tagMap:
        final length = reader.readVarint();
        final map = <String, dynamic>{};
        for (var i = 0; i < length; i++) {
          final key = poolAt(reader.readVarint());
          map[key] = _readValue(reader, poolAt);
        }
        return map;
      default:
        throw VbcDecodeException('Unknown value tag 0x${tag.toRadixString(16)}.');
    }
  }

  // ── Varint (LEB128) + zigzag ───────────────────────────────────────────

  static void _writeVarint(BytesBuilder out, int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      out.addByte((remaining & 0x7F) | 0x80);
      remaining >>= 7;
    }
    out.addByte(remaining);
  }

  static int _zigzagEncode(int value) => (value << 1) ^ (value >> 63);

  static int _zigzagDecode(int value) => (value >>> 1) ^ -(value & 1);
}

final class _ByteReader {
  final Uint8List _bytes;
  int _offset = 0;

  _ByteReader(this._bytes);

  int readByte() {
    if (_offset >= _bytes.length) {
      throw const VbcDecodeException('Unexpected end of payload.');
    }
    return _bytes[_offset++];
  }

  Uint8List readBytes(int length) {
    if (_offset + length > _bytes.length) {
      throw const VbcDecodeException('Unexpected end of payload.');
    }
    // Zero-copy view over the payload — decoding never duplicates bytes.
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return slice;
  }

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = readByte();
      result |= (byte & 0x7F) << shift;
      if (byte < 0x80) return result;
      shift += 7;
      if (shift > 63) {
        throw const VbcDecodeException('Varint too long.');
      }
    }
  }
}

/// Binary-format convenience surface on [VasterProgram].
extension VasterProgramBinary on VasterProgram {
  /// Encodes this program into VBC bytes.
  Uint8List toBytes() => const VbcCodec().encode(this);

  /// Decodes VBC bytes into a program.
  static VasterProgram fromBytes(Uint8List bytes) =>
      const VbcCodec().decode(bytes);
}
