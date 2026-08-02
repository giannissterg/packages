import 'dart:convert';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Options controlling disassembly formatting.
class DisassemblerOptions {
  final bool showStats;
  final bool showAddresses;
  final bool verbose;

  const DisassemblerOptions({
    this.showStats = true,
    this.showAddresses = true,
    this.verbose = false,
  });
}

/// Disassembler engine for `.vaster` bytecode programs.
class VasterDisassembler {
  const VasterDisassembler();

  /// Disassembles a [VasterProgram] into a formatted disassembly string.
  String disassemble(
    VasterProgram program, {
    DisassemblerOptions options = const DisassemblerOptions(),
  }) {
    final buffer = StringBuffer();

    _writeHeader(buffer, program);

    // Collect jump target addresses to annotate branch labels
    final jumpTargets = _findJumpTargets(program);

    buffer.writeln('┌─ DISASSEMBLY LISTING ─────────────────────────────────────────┐');

    for (var pc = 0; pc < program.instructions.length; pc++) {
      final inst = program.instructions[pc];

      // Print jump label if this PC is a jump target
      if (jumpTargets.contains(pc)) {
        buffer.writeln('  L_${pc.toString().padLeft(4, '0')}:');
      }

      final pcStr = pc.toString().padLeft(4, '0');
      final opName = inst.opcode.name.toUpperCase().padRight(24);
      final operandStr = _formatOperands(inst);

      if (options.showAddresses) {
        buffer.writeln('  [$pcStr]  $opName $operandStr');
      } else {
        buffer.writeln('  $opName $operandStr');
      }
    }

    buffer.writeln('└───────────────────────────────────────────────────────────────┘');

    if (options.showStats) {
      _writeStatistics(buffer, program);
    }

    return buffer.toString();
  }

  /// Disassembles a `.vaster` program from a JSON string payload.
  String disassembleJson(
    String jsonString, {
    DisassemblerOptions options = const DisassemblerOptions(),
  }) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    final program = VasterProgram.fromJson(json);
    return disassemble(program, options: options);
  }

  void _writeHeader(StringBuffer buffer, VasterProgram program) {
    buffer.writeln('═════════════════════════════════════════════════════════════════');
    buffer.writeln('  VASTER DISASSEMBLER — ${program.programName}');
    buffer.writeln('  Total Instructions: ${program.instructions.length}');
    buffer.writeln('═════════════════════════════════════════════════════════════════\n');
  }

  Set<int> _findJumpTargets(VasterProgram program) {
    final targets = <int>{};
    for (final inst in program.instructions) {
      if (inst is JumpOp) {
        targets.add(inst.targetPc);
      } else if (inst is JumpIfOp) {
        targets.add(inst.targetPc);
      } else if (inst is CallOp) {
        targets.add(inst.targetPc);
      }
    }
    return targets;
  }

  String _formatOperands(VasterInstruction inst) {
    switch (inst) {
      case PromptOp op:
        final preview = _truncate(op.promptText, 40);
        final outVar = op.outputVar != null ? ' -> r[${op.outputVar}]' : '';
        return '"$preview"$outVar';

      case MountFsOp op:
        final disk = op.diskPath != null ? ' (disk: ${op.diskPath})' : ' (memory)';
        return '${op.mountPrefix}$disk';

      case WriteFileOp op:
        final preview = _truncate(op.content, 30);
        return '${op.vfsPath} <= "$preview"';

      case ReadFileOp op:
        final outVar = op.outputVar != null ? ' -> r[${op.outputVar}]' : '';
        return '${op.vfsPath}$outVar';

      case RegisterSandboxOp op:
        return 'id=${op.sandboxId} lang=${op.language.name}';

      case ExecSandboxOp op:
        final outVar = op.outputVar != null ? ' -> r[${op.outputVar}]' : '';
        return 'id=${op.sandboxId} code="${_truncate(op.code, 30)}"$outVar';

      case CreateAgentOp op:
        return 'id=${op.descriptor.agentId} role="${op.descriptor.role}"';

      case DispatchAgentTaskOp op:
        final outVar = op.outputVar != null ? ' -> r[${op.outputVar}]' : '';
        return 'agent=${op.agentId} task="${_truncate(op.taskPrompt, 30)}"$outVar';

      case DispatchParallelTasksOp op:
        final agentIds = op.dispatches.map((d) => d.agentId).join(', ');
        return 'parallel [${op.dispatches.length} tasks]: $agentIds';

      case SendMessageOp op:
        return 'from=${op.senderId} to=${op.recipientId}';

      case PopMessageOp op:
        final outVar = op.outputVar != null ? ' -> r[${op.outputVar}]' : '';
        return 'agent=${op.agentId}$outVar';

      case ForkSessionOp op:
        return 'source=${op.sourceSessionId} -> target=${op.targetSessionId}';

      case PinContextOp op:
        return 'region=${op.regionId}';

      case SetQuotaOp op:
        return 'tokens=${op.quota.maxTokenBudget} tools=${op.quota.maxToolCallsPerTask}';

      case JumpOp op:
        final label = 'L_${op.targetPc.toString().padLeft(4, '0')}';
        return 'target=PC:${op.targetPc.toString().padLeft(4, '0')} ($label)';

      case JumpIfOp op:
        final label = 'L_${op.targetPc.toString().padLeft(4, '0')}';
        return 'if r[${op.conditionVar}] -> PC:${op.targetPc.toString().padLeft(4, '0')} ($label)';

      case SetRegisterOp op:
        return 'r[${op.registerName}] = "${_truncate(op.value.toString(), 40)}"';

      case JsonExtractOp op:
        return 'r[${op.targetVar}] = r[${op.sourceVar}].${op.jsonKey}';

      case ConcatRegisterOp op:
        final sources = op.sourceVars.map((v) => 'r[$v]').join(' + ');
        return 'r[${op.targetVar}] = $sources';

      case BeginTransactionOp _:
        return '--- TRANSACTION START ---';

      case CommitOp _:
        return '--- TRANSACTION COMMIT ---';

      case RollbackOp _:
        return '--- TRANSACTION ROLLBACK ---';

      case SelectModelOp op:
        return op.descriptor.descriptorKey;

      case CreateSessionOp op:
        final modelStr = op.modelDescriptor != null ? ' model=${op.modelDescriptor!.descriptorKey}' : '';
        return 'id=${op.sessionId}$modelStr';

      case SetSessionOp op:
        return 'id=${op.sessionId}';

      case CheckPolicyOp op:
        return 'action=${op.action.name} resource="${op.resource}"';

      case YieldHumanInteractionOp op:
        final opts = op.request.options.isNotEmpty ? ' [${op.request.options.join(', ')}]' : '';
        final outVar = op.request.outputVar != null ? ' -> r[${op.request.outputVar}]' : '';
        return 'type=${op.request.type.name} prompt="${_truncate(op.request.prompt, 30)}"$opts$outVar';

      case CallOp op:
        final label = 'L_${op.functionName}';
        final outVar = op.outputVar != null ? ' -> r[${op.outputVar}]' : '';
        return '${op.functionName}() target=PC:${op.targetPc.toString().padLeft(4, '0')} ($label)$outVar';

      case ReturnSubroutineOp op:
        final ret = op.returnRegister != null ? ' r[${op.returnRegister}]' : '';
        return '--- RETURN SUBROUTINE$ret ---';

      case HaltOp _:
        return '--- HALT ---';
    }
  }

  void _writeStatistics(StringBuffer buffer, VasterProgram program) {
    final opcodeCounts = <String, int>{};
    for (final inst in program.instructions) {
      final name = inst.opcode.name;
      opcodeCounts[name] = (opcodeCounts[name] ?? 0) + 1;
    }

    final sorted = opcodeCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    buffer.writeln('\n┌─ INSTRUCTION STATISTICS ──────────────────────────────────────┐');
    for (final entry in sorted) {
      final pct = ((entry.value / program.instructions.length) * 100).toStringAsFixed(1);
      final bar = '█' * entry.value;
      buffer.writeln('  ${entry.key.padRight(24)} ${entry.value.toString().padLeft(3)} (${pct.padLeft(5)}%) $bar');
    }
    buffer.writeln('└───────────────────────────────────────────────────────────────┘');
  }

  String _truncate(String text, int maxLength) {
    final clean = text.replaceAll('\n', ' ').trim();
    if (clean.length <= maxLength) return clean;
    return '${clean.substring(0, maxLength - 3)}...';
  }
}
