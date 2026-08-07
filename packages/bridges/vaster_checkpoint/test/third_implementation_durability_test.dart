import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// A3: durability is a CONTRACT obligation, not a downcast.
///
/// The checkpoint used to capture VFS bytes and inboxes only when the
/// subsystem happened to be the concrete in-repo class
/// (`is MemoryVasterFileSystem`, `is BasicAgentMessagingHub`). ANY other
/// implementation — a third filesystem, a distributed hub — checkpointed
/// as silently empty: no error, no warning, no bytes. These doubles are
/// deliberately NOT the in-repo classes.
void main() {
  test('a third filesystem implementation survives capture/restore',
      () async {
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    final source = _ThirdPartyFileSystem();
    vm.mountFileSystem('/third', source);
    await source.writeText('/third/notes.md', 'durable through the contract');

    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    const program = VasterProgram(
        programName: 'third_fs', instructions: [HaltOp()]);

    final json = jsonEncode(MachineCheckpoint.capture(
      runtime: runtime,
      vm: vm,
      program: program,
    ).toJson());
    await vm.shutdown();

    expect(json, contains('/third/notes.md'),
        reason: 'the third filesystem exported through the contract — '
            'the downcast version wrote nothing here');

    // Restore into a fresh VM that mounts its OWN third-party instance:
    // the contract's import hydrates it.
    final restored =
        MachineCheckpoint.fromJson(jsonDecode(json) as Map<String, dynamic>);
    final vm2 = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    addTearDown(vm2.shutdown);
    final target = _ThirdPartyFileSystem();
    vm2.mountFileSystem('/third', target);
    await restored.restoreRuntime(
      vm: vm2,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    expect(await target.readText('/third/notes.md'),
        'durable through the contract');
    expect(identical(vm2.fileSystemManager.mounts['/third'], target), isTrue,
        reason: 'restore imports INTO the mounted implementation rather '
            'than replacing it with a memory filesystem');
  });

  test('a third messaging-hub implementation survives capture/restore',
      () async {
    final hub = _ThirdPartyHub();
    hub.sendMessage(AgentMessage(
      messageId: 'm1',
      senderAgentId: 'a',
      recipientAgentId: 'b',
      payload: const {'note': 'survive me'},
    ));

    final exported = hub.exportInboxes();
    expect(exported['b'], hasLength(1),
        reason: 'the contract obligates every hub to export');

    final target = _ThirdPartyHub();
    expect(target.importInboxes(exported), 1);
    expect(target.popNextMessage('b')?.payload['note'], 'survive me');
  });
}

/// A filesystem that is deliberately not `MemoryVasterFileSystem`.
final class _ThirdPartyFileSystem implements VasterFileSystem {
  final Map<String, Uint8List> _files = {};

  @override
  Future<String> writeText(String path, String content) =>
      writeBytes(path, Uint8List.fromList(utf8.encode(content)));

  @override
  Future<String> writeBytes(String path, Uint8List bytes) async {
    _files[path] = bytes;
    return path;
  }

  @override
  Future<String> readText(String path) async =>
      utf8.decode(await readBytes(path));

  @override
  Future<Uint8List> readBytes(String path) async {
    final bytes = _files[path];
    if (bytes == null) throw StateError('not found: $path');
    return bytes;
  }

  @override
  Map<String, String> exportFilesBase64() =>
      {for (final e in _files.entries) e.key: base64Encode(e.value)};

  @override
  int importFilesBase64(Map<String, String> files) {
    for (final e in files.entries) {
      _files[e.key] = base64Decode(e.value);
    }
    return files.length;
  }

  @override
  Future<FileSystemSnapshot> createSnapshot() async =>
      FileSystemSnapshot(files: Map.of(_files));

  @override
  Future<int> restoreSnapshot(FileSystemSnapshot snapshot) async {
    _files
      ..clear()
      ..addAll(snapshot.files);
    return snapshot.files.length;
  }

  @override
  Future<bool> exists(String path) async => _files.containsKey(path);

  @override
  Future<bool> delete(String path, {bool recursive = false}) async =>
      _files.remove(path) != null;

  @override
  Future<FileDescriptor?> getDescriptor(String path) async =>
      _files.containsKey(path)
          ? FileDescriptor(
              path: path,
              sizeBytes: _files[path]!.length,
              modifiedTimestamp: DateTime.fromMillisecondsSinceEpoch(0))
          : null;

  @override
  Future<List<VirtualNode>> listDirectory(String path,
          {bool recursive = false}) async =>
      const [];
}

/// A hub that is deliberately not `BasicAgentMessagingHub`.
final class _ThirdPartyHub implements AgentMessagingHub {
  final Map<String, List<AgentMessage>> _inboxes = {};

  @override
  String sendMessage(AgentMessage message) {
    _inboxes.putIfAbsent(message.recipientAgentId, () => []).add(message);
    return message.messageId;
  }

  @override
  List<AgentMessage> getInbox(String agentId) =>
      List.unmodifiable(_inboxes[agentId] ?? const []);

  @override
  Stream<AgentMessage> getMessageStream(String agentId) => const Stream.empty();

  @override
  AgentMessage? popNextMessage(String agentId) {
    final inbox = _inboxes[agentId];
    if (inbox == null || inbox.isEmpty) return null;
    return inbox.removeAt(0);
  }

  @override
  int clearInbox(String agentId) => _inboxes.remove(agentId)?.length ?? 0;

  @override
  Map<String, List<Map<String, dynamic>>> exportInboxes() => {
        for (final e in _inboxes.entries)
          e.key: [for (final m in e.value) m.toJson()],
      };

  @override
  int importInboxes(Map<String, List<Map<String, dynamic>>> inboxes) {
    var hydrated = 0;
    for (final e in inboxes.entries) {
      _inboxes[e.key] = [
        for (final m in e.value) AgentMessage.fromJson(Map<String, dynamic>.from(m)),
      ];
      hydrated += e.value.length;
    }
    return hydrated;
  }

  @override
  Future<bool> close() async => true;
}
