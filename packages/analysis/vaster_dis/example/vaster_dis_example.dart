import 'dart:convert';

import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  print('================================================================');
  print('          Vaster Bytecode Disassembler Demonstration           ');
  print('================================================================\n');

  // Build a sample program with branches and opcodes
  const program = VasterProgram(
    programName: 'demo_pipeline_program',
    instructions: [
      MountFsOp(mountPrefix: '/workspace'),
      WriteFileOp(vfsPath: '/workspace/brief.md', content: '# Project Brief\nBuild API Gateway.'),
      CreateAgentOp(
        descriptor: AgentDescriptor(
          agentId: 'architect',
          name: 'Lead Architect',
          role: 'Architect',
          systemInstruction: 'Design architecture document',
        ),
      ),
      DispatchAgentTaskOp(
        agentId: 'architect',
        taskPrompt: 'Design architecture document',
        outputVar: 'arch_doc',
      ),
      JumpIfOp(targetPc: 6, conditionVar: 'arch_doc'),
      HaltOp(),
      WriteFileOp(vfsPath: '/workspace/docs/arch.md', content: r'${arch_doc}'),
      HaltOp(),
    ],
  );

  // Serialize to JSON string (.vaster format)
  final vasterJson = const JsonEncoder.withIndent('  ').convert(program.toJson());

  print('1. Raw .vaster JSON Bytecode Format (first 300 chars):');
  print('${vasterJson.substring(0, 300)}...\n');

  print('2. Disassembled Instruction Listing:');
  const disassembler = VasterDisassembler();
  final disassembly = disassembler.disassemble(program);

  print(disassembly);
}
