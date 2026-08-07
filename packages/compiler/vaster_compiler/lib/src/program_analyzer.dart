import 'package:vaster_context/vaster_context.dart';
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
///  * `undefined_context_class` (error) — `AddContextOp.className` not in the
///    program's class table (undefined-symbol check for the context linker)
///  * `invalid_context_class_table` (error) — structurally invalid header table
class ProgramAnalyzer {
  const ProgramAnalyzer();

  List<CompileDiagnostic> analyze(VasterProgram program) {
    final diagnostics = <CompileDiagnostic>[];
    final instructions = program.instructions;

    // ── Context-class verification (static, undefined-symbol style) ──────
    final classTable = program.contextClasses != null
        ? ContextClassTable.fromJson(program.contextClasses!)
        : ContextClassTable.standard;
    for (final issue in classTable.validate()) {
      diagnostics.add(
        CompileDiagnostic(
          severity: CompileSeverity.error,
          code: 'invalid_context_class_table',
          message: issue,
        ),
      );
    }
    for (var pc = 0; pc < instructions.length; pc++) {
      final inst = instructions[pc];
      if (inst is AddContextOp && inst.className != null && !classTable.contains(inst.className!)) {
        diagnostics.add(
          CompileDiagnostic(
            severity: CompileSeverity.error,
            code: 'undefined_context_class',
            message:
                'AddContextOp at PC $pc references context class '
                '"${inst.className}", which the program\'s class table does '
                'not declare (declared: '
                '${classTable.classes.keys.toList().join(', ')}).',
          ),
        );
      }
    }

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
        case PushErrorHandlerOp(:final targetPc):
          jumpTargets.add(targetPc); // catch blocks are reachable via handlers
          _checkJumpRange(diagnostics, pc, targetPc, instructions.length);
        case DecideOp(:final branches, :final defaultLabel):
          if (branches.isEmpty) {
            diagnostics.add(
              CompileDiagnostic(
                severity: CompileSeverity.error,
                code: 'decide_no_branches',
                message: 'DecideOp has no branches to choose from.',
                pc: pc,
              ),
            );
          }
          final labels = <String>{};
          for (final branch in branches) {
            jumpTargets.add(branch.targetPc);
            _checkJumpRange(diagnostics, pc, branch.targetPc, instructions.length);
            if (!labels.add(branch.label)) {
              diagnostics.add(
                CompileDiagnostic(
                  severity: CompileSeverity.error,
                  code: 'decide_duplicate_label',
                  message:
                      'DecideOp declares branch label "${branch.label}" '
                      'more than once.',
                  pc: pc,
                ),
              );
            }
          }
          if (defaultLabel != null && !labels.contains(defaultLabel)) {
            diagnostics.add(
              CompileDiagnostic(
                severity: CompileSeverity.error,
                code: 'decide_unknown_default',
                message:
                    'DecideOp defaultLabel "$defaultLabel" is not among '
                    'its branch labels.',
                pc: pc,
              ),
            );
          }
        case CreateAgentOp(:final descriptor):
          if (!createdAgents.add(descriptor.agentId)) {
            diagnostics.add(
              CompileDiagnostic(
                severity: CompileSeverity.warning,
                code: 'duplicate_agent',
                message: 'Agent "${descriptor.agentId}" is created more than once.',
                pc: pc,
              ),
            );
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

    CompileDiagnostic? checkRead(int pc, String register) {
      read.add(register);
      if (written.contains(register)) return null;
      final diagnostic = CompileDiagnostic(
        severity: CompileSeverity.warning,
        code: 'read_before_write',
        message: 'Register "$register" is read before any instruction writes it.',
        pc: pc,
      );
      diagnostics.add(diagnostic);
      return diagnostic;
    }

    // `${name}` interpolation references are register reads — check the
    // wiring at compile time (the runtime leaves unresolvable refs verbatim).
    List<CompileDiagnostic> checkInterpolationReads(int pc, VasterInstruction inst) {
      final added = <CompileDiagnostic>[];
      for (final field in _interpolatedFields(inst)) {
        for (final match in RegisterInterpolation.token.allMatches(field)) {
          final name = match.group(1);
          if (name == null) continue; // `$$` escape
          read.add(name);
          if (!written.contains(name)) {
            final diagnostic = CompileDiagnostic(
              severity: CompileSeverity.warning,
              code: 'unresolved_interpolation_ref',
              message:
                  'Prompt/content interpolates "\${$name}" but no prior '
                  'instruction binds it — the reference will be left verbatim '
                  'at runtime unless seeded externally.',
              pc: pc,
            );
            diagnostics.add(diagnostic);
            added.add(diagnostic);
          }
        }
      }
      return added;
    }

    for (var pc = 0; pc < instructions.length; pc++) {
      final inst = instructions[pc];
      checkInterpolationReads(pc, inst);
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

        // Context ops: register reads/writes + region reference tracking.
        case AddContextOp(:final sourceVar):
          if (sourceVar != null) checkRead(pc, sourceVar);
        case CompressContextOp(:final outputVar):
          if (outputVar != null) written.add(outputVar);

        case CompareRegisterOp(:final leftVar, :final rightVar, :final targetVar):
          checkRead(pc, leftVar);
          if (rightVar != null) checkRead(pc, rightVar);
          written.add(targetVar);
        case IncrementRegisterOp(:final registerName):
          // Read-modify-write, but a missing register is defined as 0 — a
          // standalone increment is legal, so no read-before-write warning.
          read.add(registerName);
          written.add(registerName);
        case PushErrorHandlerOp(:final errorVar):
          // The runtime writes the error text when the handler fires.
          written.add(errorVar);

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
            diagnostics.add(
              CompileDiagnostic(
                severity: CompileSeverity.warning,
                code: 'unknown_agent',
                message: 'Task dispatched to agent "$agentId" which no CreateAgentOp defines.',
                pc: pc,
              ),
            );
          }
        case DispatchParallelTasksOp(:final dispatches):
          for (final dispatch in dispatches) {
            if (dispatch.outputVar != null) written.add(dispatch.outputVar!);
            if (!createdAgents.contains(dispatch.agentId)) {
              diagnostics.add(
                CompileDiagnostic(
                  severity: CompileSeverity.warning,
                  code: 'unknown_agent',
                  message:
                      'Parallel task targets agent "${dispatch.agentId}" which no CreateAgentOp defines.',
                  pc: pc,
                ),
              );
            }
          }
        case YieldHumanInteractionOp(:final request):
          // The HITL controller writes both the output var and its status
          // sibling when the human responds.
          final outputVar = request.outputVar;
          if (outputVar != null) {
            written.add(outputVar);
            written.add(hitlStatusRegister(outputVar));
          }
        case DecideOp(:final outputVar):
          // The engine writes the chosen label and the model's rationale.
          if (outputVar != null) {
            written.add(outputVar);
            written.add(decideRationaleRegister(outputVar));
          }
        case SetSessionOp(:final sessionId):
          if (!createdSessions.contains(sessionId)) {
            diagnostics.add(
              CompileDiagnostic(
                severity: CompileSeverity.warning,
                code: 'unknown_session',
                message: 'SetSessionOp targets session "$sessionId" which no CreateSessionOp defines.',
                pc: pc,
              ),
            );
          }
        default:
          break;
      }
    }

    // ── Context region references (info only: regions are routinely
    //    provisioned outside the program — sources, sessions, host code) ──
    final declaredRegions = <String>{
      for (final inst in instructions)
        if (inst is AddContextOp) inst.regionId,
    };
    CompileDiagnostic? checkRegionRef(int pc, String opName, String regionId) {
      if (declaredRegions.contains(regionId)) return null;
      final diagnostic = CompileDiagnostic(
        severity: CompileSeverity.info,
        code: 'ctx_unknown_region',
        message:
            '$opName references region "$regionId" with no preceding '
            'AddContextOp in this program (may be provisioned externally).',
        pc: pc,
      );
      diagnostics.add(diagnostic);
      return diagnostic;
    }

    for (var pc = 0; pc < instructions.length; pc++) {
      switch (instructions[pc]) {
        case EvictContextOp(:final regionId):
          checkRegionRef(pc, 'EvictContext', regionId);
        case PinContextOp(:final regionId):
          checkRegionRef(pc, 'PinContext', regionId);
        case UnpinContextOp(:final regionId):
          checkRegionRef(pc, 'UnpinContext', regionId);
        case SetContextPolicyOp(:final regionId):
          checkRegionRef(pc, 'SetContextPolicy', regionId);
        case CompressContextOp(:final regionId):
          if (regionId != null) checkRegionRef(pc, 'CompressContext', regionId);
        default:
          break;
      }
    }

    // ── Unused registers (skip well-known sinks) ─────────────────────────
    for (final register in written.difference(read)) {
      if (register == '__output__' ||
          register.endsWith(hitlStatusSuffix) ||
          register.endsWith(decideRationaleSuffix)) {
        continue;
      }
      diagnostics.add(
        CompileDiagnostic(
          severity: CompileSeverity.info,
          code: 'unused_register',
          message: 'Register "$register" is written but never read.',
        ),
      );
    }

    // ── Unreachable code (forward reachability propagation) ──────────────
    // An instruction is reachable iff the previous one falls through to it,
    // or it is a jump target. (One-pass approximation: all jump targets are
    // treated as reachable — conservative, never a false positive.)
    var reachable = true;
    for (var pc = 0; pc < instructions.length; pc++) {
      if (jumpTargets.contains(pc)) reachable = true;
      if (!reachable) {
        diagnostics.add(
          CompileDiagnostic(
            severity: CompileSeverity.warning,
            code: 'unreachable_code',
            message:
                'Instruction ${instructions[pc].opcode.name} is unreachable '
                '(no control path leads to it).',
            pc: pc,
          ),
        );
        continue;
      }
      final inst = instructions[pc];
      if (inst is HaltOp || inst is JumpOp || inst is DecideOp) {
        reachable = false; // DecideOp always transfers — no fall-through
      }
    }

    return diagnostics;
  }

  /// The interpolated string fields of [inst], per the RegisterInterpolation
  /// spec in vaster_instruction.
  List<String> _interpolatedFields(VasterInstruction inst) => switch (inst) {
    PromptOp(:final promptText) => [promptText],
    DispatchAgentTaskOp(:final taskPrompt) => [taskPrompt],
    DispatchParallelTasksOp(:final dispatches) => [for (final d in dispatches) d.taskPrompt],
    WriteFileOp(:final vfsPath, :final content) => [vfsPath, content],
    ReadFileOp(:final vfsPath) => [vfsPath],
    ExecSandboxOp(:final code) => [code],
    AddContextOp(:final text) => [text],
    DecideOp(:final prompt) => [prompt],
    YieldHumanInteractionOp(:final request) => [request.prompt],
    SendMessageOp(:final payload) => _stringLeaves(payload),
    _ => const [],
  };

  List<String> _stringLeaves(Object? value) => switch (value) {
    String s => [s],
    Map m => [for (final v in m.values) ..._stringLeaves(v)],
    List l => [for (final v in l) ..._stringLeaves(v)],
    _ => const [],
  };

  CompileDiagnostic? _checkJumpRange(
    List<CompileDiagnostic> diagnostics,
    int pc,
    int targetPc,
    int programLength,
  ) {
    // A target equal to length is a jump-to-end (program exit) — legal.
    if (targetPc >= 0 && targetPc <= programLength) return null;
    final diagnostic = CompileDiagnostic(
      severity: CompileSeverity.error,
      code: 'jump_out_of_range',
      message: 'Jump target PC $targetPc is outside the program (length $programLength).',
      pc: pc,
    );
    diagnostics.add(diagnostic);
    return diagnostic;
  }
}
