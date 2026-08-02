import 'package:vaster_instruction/vaster_instruction.dart';

import 'compile_diagnostics.dart';

/// Static semantic analysis over a flat [VasterProgram].
///
/// Checks performed:
///  * `jump_out_of_range`   (error)   — jump target outside `[0, length]`
///  * `read_before_write`   (warning) — register read with no prior write
///  * `unknown_agent`       (warning) — task dispatched to an agent never created
///  * `unknown_session`     (warning) — `SetSessionOp` for a session never created
///  * `duplicate_agent`     (warning) — same agent id created twice
///  * `unreachable_code`    (warning) — instruction that no control path reaches
///  * `unused_register`     (info)    — written register that nothing reads
class ProgramAnalyzer {
  const ProgramAnalyzer();

  List<CompileDiagnostic> analyze(VasterProgram program) {
    final diagnostics = <CompileDiagnostic>[];
    final instructions = program.instructions;

    // ── Collect jump targets, agent/session definitions ──────────────────
    final jumpTargets = <int>{};
    final createdAgents = <String>{};
    final createdSessions = <String>{};

    for (var pc = 0; pc < instructions.length; pc++) {
      final inst = instructions[pc];
      switch (inst) {
        case JumpOp(:final targetPc):
          jumpTargets.add(targetPc);
          _checkJumpRange(diagnostics, pc, targetPc, instructions.length);
        case JumpIfOp(:final targetPc):
          jumpTargets.add(targetPc);
          _checkJumpRange(diagnostics, pc, targetPc, instructions.length);
        case CallOp(:final targetPc):
          jumpTargets.add(targetPc);
          _checkJumpRange(diagnostics, pc, targetPc, instructions.length);
        case CreateAgentOp(:final descriptor):
          if (!createdAgents.add(descriptor.agentId)) {
            diagnostics.add(CompileDiagnostic(
              severity: CompileSeverity.warning,
              code: 'duplicate_agent',
              message: 'Agent "${descriptor.agentId}" is created more than once.',
              pc: pc,
            ));
          }
        case CreateSessionOp(:final sessionId):
          createdSessions.add(sessionId);
        default:
          break;
      }
    }

    // ── Def-use over registers + reference checks (linear order) ─────────
    final written = <String>{};
    final read = <String>{};

    void checkRead(int pc, String register) {
      read.add(register);
      if (!written.contains(register)) {
        diagnostics.add(CompileDiagnostic(
          severity: CompileSeverity.warning,
          code: 'read_before_write',
          message: 'Register "$register" is read before any instruction writes it.',
          pc: pc,
        ));
      }
    }

    for (var pc = 0; pc < instructions.length; pc++) {
      final inst = instructions[pc];
      switch (inst) {
        // Reads first (an op may read then write).
        case JumpIfOp(:final conditionVar):
          checkRead(pc, conditionVar);
        case JsonExtractOp(:final sourceVar, :final targetVar):
          checkRead(pc, sourceVar);
          written.add(targetVar);
        case ConcatRegisterOp(:final sourceVars, :final targetVar):
          for (final source in sourceVars) {
            checkRead(pc, source);
          }
          written.add(targetVar);
        case ReturnSubroutineOp(:final returnRegister):
          if (returnRegister != null) checkRead(pc, returnRegister);

        // Pure writes.
        case SetRegisterOp(:final registerName):
          written.add(registerName);
        case PromptOp(:final outputVar) ||
              ReadFileOp(:final outputVar) ||
              ExecSandboxOp(:final outputVar) ||
              CallOp(:final outputVar) ||
              PopMessageOp(:final outputVar):
          if (outputVar != null) written.add(outputVar);
        case DispatchAgentTaskOp(:final outputVar, :final agentId):
          if (outputVar != null) written.add(outputVar);
          if (!createdAgents.contains(agentId)) {
            diagnostics.add(CompileDiagnostic(
              severity: CompileSeverity.warning,
              code: 'unknown_agent',
              message:
                  'Task dispatched to agent "$agentId" which no CreateAgentOp defines.',
              pc: pc,
            ));
          }
        case DispatchParallelTasksOp(:final dispatches):
          for (final dispatch in dispatches) {
            if (dispatch.outputVar != null) written.add(dispatch.outputVar!);
            if (!createdAgents.contains(dispatch.agentId)) {
              diagnostics.add(CompileDiagnostic(
                severity: CompileSeverity.warning,
                code: 'unknown_agent',
                message:
                    'Parallel task targets agent "${dispatch.agentId}" which no CreateAgentOp defines.',
                pc: pc,
              ));
            }
          }
        case YieldHumanInteractionOp(:final request):
          // The HITL controller writes both the output var and its status
          // sibling when the human responds.
          final outputVar = request.outputVar;
          if (outputVar != null) {
            written.add(outputVar);
            written.add('${outputVar}_status');
          }
        case SetSessionOp(:final sessionId):
          if (!createdSessions.contains(sessionId)) {
            diagnostics.add(CompileDiagnostic(
              severity: CompileSeverity.warning,
              code: 'unknown_session',
              message:
                  'SetSessionOp targets session "$sessionId" which no CreateSessionOp defines.',
              pc: pc,
            ));
          }
        default:
          break;
      }
    }

    // ── Unused registers (skip well-known sinks) ─────────────────────────
    for (final register in written.difference(read)) {
      if (register == '__output__' || register.endsWith('_status')) continue;
      diagnostics.add(CompileDiagnostic(
        severity: CompileSeverity.info,
        code: 'unused_register',
        message: 'Register "$register" is written but never read.',
      ));
    }

    // ── Unreachable code (forward reachability propagation) ──────────────
    // An instruction is reachable iff the previous one falls through to it,
    // or it is a jump target. (One-pass approximation: all jump targets are
    // treated as reachable — conservative, never a false positive.)
    var reachable = true;
    for (var pc = 0; pc < instructions.length; pc++) {
      if (jumpTargets.contains(pc)) reachable = true;
      if (!reachable) {
        diagnostics.add(CompileDiagnostic(
          severity: CompileSeverity.warning,
          code: 'unreachable_code',
          message:
              'Instruction ${instructions[pc].opcode.name} is unreachable '
              '(no control path leads to it).',
          pc: pc,
        ));
        continue;
      }
      final inst = instructions[pc];
      if (inst is HaltOp || inst is JumpOp) reachable = false;
    }

    return diagnostics;
  }

  void _checkJumpRange(
    List<CompileDiagnostic> diagnostics,
    int pc,
    int targetPc,
    int programLength,
  ) {
    // A target equal to length is a jump-to-end (program exit) — legal.
    if (targetPc < 0 || targetPc > programLength) {
      diagnostics.add(CompileDiagnostic(
        severity: CompileSeverity.error,
        code: 'jump_out_of_range',
        message:
            'Jump target PC $targetPc is outside the program (length $programLength).',
        pc: pc,
      ));
    }
  }
}
