import 'package:vaster_sandbox/vaster_sandbox.dart';

void main() {
  print('=== Vaster Sandbox Primitives Example ===');

  const descriptor = SandboxDescriptor(
    sandboxId: 'demo_sb',
    type: 'isolate',
    description: 'Demo sandbox descriptor',
  );

  print('Descriptor: $descriptor');
}
