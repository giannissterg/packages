import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Subroutines & Function Calls Architecture', () {
    late VasterVirtualMachine vm;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()),
      );
    });

    test('compiles DefineFunctionNode and CallFunctionNode into CallOp and ReturnSubroutineOp', () {
      const compiler = BasicWorkflowCompiler();

      final pipeline = PipelineNode(
        spec: const PipelineSpec(name: 'subroutine_compiler_test'),
        bodyNodes: [
          const CallFunctionNode(
            functionName: 'generate_docs',
            outputVariable: 'doc_output',
          ),
          const DefineFunctionNode(
            functionName: 'generate_docs',
            bodyNodes: [
              WriteDocumentNode(path: '/mem/doc.md', content: '# Documentation'),
              ReturnNode(returnVariable: 'doc_output'),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);

      final calls = program.instructions.whereType<CallOp>().toList();
      final returns = program.instructions.whereType<ReturnSubroutineOp>().toList();

      expect(calls, hasLength(1));
      expect(calls.first.functionName, equals('generate_docs'));
      expect(returns, hasLength(1));
      expect(returns.first.returnRegister, equals('doc_output'));
    });

    test('executes subroutine function call and returns execution to caller PC', () async {
      const compiler = BasicWorkflowCompiler();

      final pipeline = PipelineNode(
        spec: const PipelineSpec(name: 'subroutine_e2e_test'),
        bodyNodes: [
          const WriteDocumentNode(path: '/mem/start.txt', content: 'START'),
          const CallFunctionNode(functionName: 'helper_func'),
          const WriteDocumentNode(path: '/mem/end.txt', content: 'END'),
          const DefineFunctionNode(
            functionName: 'helper_func',
            bodyNodes: [
              WriteDocumentNode(path: '/mem/subroutine.txt', content: 'SUBROUTINE_EXECUTED'),
              ReturnNode(),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);
      final runtime = VasterRuntime(vm: vm, policy: ExecutionPolicy.unlimited);

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));

      final startTxt = await vm.fileSystemManager.resolveFileSystem('/mem/start.txt').readText('/mem/start.txt');
      final subTxt = await vm.fileSystemManager.resolveFileSystem('/mem/subroutine.txt').readText('/mem/subroutine.txt');
      final endTxt = await vm.fileSystemManager.resolveFileSystem('/mem/end.txt').readText('/mem/end.txt');

      expect(startTxt, equals('START'));
      expect(subTxt, equals('SUBROUTINE_EXECUTED'));
      expect(endTxt, equals('END'));
    });
  });
}
