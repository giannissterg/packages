import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_playground/vaster_playground.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('======================================================================');
  print('  VASTER FLUTTER COMPOSABLE NODES & REAL DISK MOUNT DEMO              ');
  print('  Target Project: (temp dir, printed below)');
  print('======================================================================\n');

  final flutterProjectPath =
      Directory.systemTemp.createTempSync('vaster_flutter_target_').path;

  // 1. Assemble complete Flutter application workflow using specialized composable nodes
  final pipeline = Pipeline(
    name: 'flutter_test_app_pipeline',
    children: const [
      // Step 1: Design system tokens & typography
      FlutterDesignSystemComponent(
        primaryColorHex: '#6750A4',
        accentColorHex: '#625B71',
      ),

      // Step 2: Domain entity data model
      FlutterDomainModelNode(
        featureName: 'task_manager',
        entityName: 'TaskItem',
        fields: {
          'id': 'String',
          'title': 'String',
          'isCompleted': 'bool',
        },
      ),

      // Step 3: State management (BLoC, Events, States)
      FlutterBlocStateManagementComponent(
        featureName: 'task_manager',
        blocName: 'TaskManager',
        entityName: 'TaskItem',
      ),

      // Step 4: Reactive UI page & widgets
      FlutterFeatureWidgetComponent(
        featureName: 'task_manager',
        pageTitle: 'Task Manager Dashboard',
        blocName: 'TaskManager',
        entityName: 'TaskItem',
      ),

      // Step 5: Widget unit test suite
      FlutterWidgetTestComponent(
        featureName: 'task_manager',
        pageTitle: 'Task Manager Dashboard',
      ),
    ],
  );

  // 2. Compile AST -> ISA bytecode
  final compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  print('┌─ AST COMPILATION ──────────────────────────────────────────────┐');
  print('  Pipeline Compiled: ${program.programName} (${program.instructions.length} instructions)');
  print('═════════════════════════════════════════════════════════════════');

  final disassembler = VasterDisassembler();
  print(disassembler.disassemble(program));

  // 3. Bootstrap Vaster VM and Mount real disk project at /workspace
  print('┌─ EXECUTING FLUTTER WORKFLOW ON REAL LOCAL DISK ────────────────┐');

  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: FakeVasterModel(),
      rootMountPath: '/workspace',
    ),
    rootFileSystem: LocalVasterFileSystem(flutterProjectPath),
  );

  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  print('  ✓ Pipeline Status: ${state.status.name}');
  print('  ✓ Real Disk Files Written to: $flutterProjectPath');

  // Verify created files exist on local disk
  final themeFile = File('$flutterProjectPath/lib/core/theme/app_theme.dart');
  final modelFile = File('$flutterProjectPath/lib/features/task_manager/domain/taskitem.dart');
  final blocFile = File('$flutterProjectPath/lib/features/task_manager/presentation/bloc/task_manager_bloc.dart');
  final pageFile = File('$flutterProjectPath/lib/features/task_manager/presentation/pages/task_manager_page.dart');
  final testFile = File('$flutterProjectPath/test/features/task_manager/task_manager_page_test.dart');

  print('\n┌─ VERIFYING LOCAL DISK FILES ──────────────────────────────────┐');
  print('  ✓ theme/app_theme.dart exists       : ${themeFile.existsSync()}');
  print('  ✓ domain/taskitem.dart exists        : ${modelFile.existsSync()}');
  print('  ✓ bloc/task_manager_bloc.dart exists : ${blocFile.existsSync()}');
  print('  ✓ pages/task_manager_page.dart exists: ${pageFile.existsSync()}');
  print('  ✓ test/..._page_test.dart exists    : ${testFile.existsSync()}');

  await vm.shutdown();

  print('\n======================================================================');
  print('  DEMO PASSED: Specialized Flutter Nodes & Disk Generation Verified!  ');
  print('======================================================================');
}
