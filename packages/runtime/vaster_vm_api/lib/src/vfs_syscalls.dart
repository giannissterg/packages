import 'vaster_vm_interface.dart';

/// The two built-in VFS syscalls models can call as tools.
///
/// One implementation, two exposure points: the runtime's tool loop executes
/// these names through its policy-gated built-in path, and the VM bootstrap
/// registers them as advertised [FunctionTool]s for agents and direct
/// tool-manager callers. Both delegate here — duplicated handlers drifting
/// apart was a fidelity bug waiting to happen. Policy checks stay with the
/// callers that own a policy (the runtime's guard); the syscall itself only
/// touches the VFS.
final class VfsSyscalls {
  static const String writeFileName = 'write_file';
  static const String readFileName = 'read_file';

  static Future<Map<String, dynamic>> writeFile(
      VasterVirtualMachine vm, Map<String, dynamic> args) async {
    final path = args['path']?.toString() ?? '';
    final content = args['content']?.toString() ?? '';
    await vm.fileSystemManager.resolveFileSystem(path).writeText(path, content);
    return {'status': 'ok', 'path': path};
  }

  static Future<Map<String, dynamic>> readFile(
      VasterVirtualMachine vm, Map<String, dynamic> args) async {
    final path = args['path']?.toString() ?? '';
    final content =
        await vm.fileSystemManager.resolveFileSystem(path).readText(path);
    return {'content': content};
  }
}
