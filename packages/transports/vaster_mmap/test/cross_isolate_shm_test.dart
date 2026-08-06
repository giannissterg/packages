import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

/// Cross-isolate substrate proofs (ZC-P1).
///
/// Every prior "cross-process" test in this package shared one isolate: two
/// mappings, one thread. These tests put a second *isolate* — a genuinely
/// parallel thread with its own attach path through the full `shm_open`
/// ladder — on the other side of the segment. What isolates cannot prove
/// (state surviving process death) is proven by the documented CLI
/// transcript in docs/ZERO_COPY.md, the same standing PROVE_IT.md has for
/// durability.
void main() {
  test('an isolate attaches a segment by name and its writes are visible',
      () async {
    final name = 'vaster_xiso_seg_${DateTime.now().microsecondsSinceEpoch}';
    final owner = ShmSegment.open(name: name, size: 4096);
    addTearDown(() => owner.close());
    owner.view(0, 4).setAll(0, [1, 2, 3, 4]);

    final result = await Isolate.run(() {
      final attached = ShmSegment.attach(name: name, size: 4096);
      final seen = List<int>.from(attached.view(0, 4));
      attached.view(4, 1)[0] = 0x5A; // reply through the pages
      attached.close(); // attacher close never unlinks
      return seen;
    });

    expect(result, [1, 2, 3, 4],
        reason: 'the isolate read through its own independent mapping');
    expect(owner.view(4, 1)[0], 0x5A,
        reason: 'the isolate\'s write landed on the shared pages');
  });

  test('frame round-trip: allocate + native-path fill here, attach there',
      () async {
    final name = 'vaster_xiso_frame_${DateTime.now().microsecondsSinceEpoch}';
    final frame = SharedMemoryFrame.allocate(name, payloadLength: 8, meta: 42);
    addTearDown(() => frame.close(unlink: true));
    expect(frame.isOwner, isTrue);

    // Fill through the pointer path — exactly what an FFI engine does.
    final p = frame.payloadPointer;
    for (var i = 0; i < 8; i++) {
      p[i] = i * 11;
    }

    final (seenMeta, seenBytes) = await Isolate.run(() {
      final attached = SharedMemoryFrame.attach(name);
      final out = (attached.meta, Uint8List.fromList(attached.bytes));
      attached.close();
      return out;
    });

    expect(seenMeta, 42);
    expect(seenBytes, [for (var i = 0; i < 8; i++) i * 11]);
  });

  test('allocate on an existing name attaches instead of rewriting',
      () async {
    final name = 'vaster_xiso_alloc_${DateTime.now().microsecondsSinceEpoch}';
    final first = SharedMemoryFrame.allocate(name, payloadLength: 4, meta: 7);
    addTearDown(() => first.close(unlink: true));
    first.bytes.setAll(0, [9, 9, 9, 9]);

    final second = SharedMemoryFrame.allocate(name, payloadLength: 4);
    expect(second.isOwner, isFalse);
    expect(second.meta, 7, reason: 'meta comes from the existing header');
    expect(second.bytes, [9, 9, 9, 9]);
    second.close();

    expect(() => SharedMemoryFrame.allocate(name, payloadLength: 5),
        throwsStateError);
  });

  test('SPSC ring survives a genuinely parallel producer', () async {
    final name = 'vaster_xiso_ring_${DateTime.now().microsecondsSinceEpoch}';
    // Small capacity forces many wrap-arounds under contention.
    final ring = SharedMemoryRing(shmName: name, capacity: 8192);
    addTearDown(() => ring.close());

    const packetCount = 3000;

    // Producer: a real OS thread, attaching by name through the full
    // ladder (header probe learns capacity). Payload i = [i lo, i hi,
    // then (len-2) bytes of i % 251] so any torn publication is detectable.
    final producer = Isolate.run(() {
      final tx = SharedMemoryRing.attach(name);
      for (var i = 0; i < packetCount; i++) {
        final len = 2 + (i * 7) % 600;
        final packet = Uint8List(len);
        packet[0] = i & 0xFF;
        packet[1] = (i >> 8) & 0xFF;
        packet.fillRange(2, len, i % 251);
        // Typed backpressure: spin until the consumer drains.
        while (!tx.tryWritePacket(packet)) {}
      }
      tx.close(unlink: false);
    });

    var received = 0;
    while (received < packetCount) {
      final packet = ring.readPacket();
      if (packet == null) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      final expectedLen = 2 + (received * 7) % 600;
      expect(packet.length, expectedLen,
          reason: 'packet $received length must match — no tearing');
      expect(packet[0] | (packet[1] << 8), received & 0xFFFF,
          reason: 'strict FIFO order under real parallelism');
      for (var j = 2; j < packet.length; j++) {
        if (packet[j] != received % 251) {
          fail('packet $received byte $j corrupted: ${packet[j]} '
              '(expected ${received % 251}) — publication order violated');
        }
      }
      received++;
    }
    await producer;
    expect(ring.readPacket(), isNull, reason: 'exactly $packetCount packets');
  });

  test('duplex rings between isolates: request/response echo', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final reqName = 'vaster_xiso_req_$stamp';
    final resName = 'vaster_xiso_res_$stamp';
    final req = SharedMemoryRing(shmName: reqName, capacity: 65536);
    final res = SharedMemoryRing(shmName: resName, capacity: 65536);
    addTearDown(() {
      req.close();
      res.close();
    });

    const rounds = 200;
    final echoServer = Isolate.run(() {
      final rx = SharedMemoryRing.attach(reqName);
      final tx = SharedMemoryRing.attach(resName);
      var served = 0;
      while (served < rounds) {
        final msg = rx.readString();
        if (msg == null) continue;
        tx.writeString('echo:$msg');
        served++;
      }
      rx.close(unlink: false);
      tx.close(unlink: false);
    });

    for (var i = 0; i < rounds; i++) {
      req.writeString('ping$i');
      String? reply;
      while (reply == null) {
        reply = res.readString();
        if (reply == null) await Future<void>.delayed(Duration.zero);
      }
      expect(reply, 'echo:ping$i');
    }
    await echoServer;
  });
}
