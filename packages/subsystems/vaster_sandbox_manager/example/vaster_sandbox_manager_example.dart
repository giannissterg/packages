import 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';

void main() async {
  print('=== Vaster Sandbox Manager Example ===');

  final manager = BasicSandboxManager();
  manager.registerSandbox(
    IsolateCodeSandbox(
      descriptor: const SandboxDescriptor(
        sandboxId: 'iso_demo',
        type: 'isolate',
        description: 'Demo Isolate',
      ),
      evaluator: (code, inputs) => 'Demo evaluation success',
    ),
  );

  final tool = manager.createSandboxTool(sandboxId: 'iso_demo');
  print('Created Sandbox ExecutableTool: ${tool.name}');

  print('Done!');
}
