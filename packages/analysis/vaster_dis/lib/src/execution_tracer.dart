import 'dart:convert';

import 'package:vaster_instruction/vaster_instruction.dart';

import 'package:vaster_runtime/vaster_runtime.dart';

/// Live disassembly-style execution tracer for a [VasterRuntime].
///
/// Attaches to the runtime's [VasterRuntime.stepObserver] and emits one line
/// per executed instruction — program counter, opcode, operand summary, token
/// spend delta, and step timing — plus the register writes the instruction
/// caused:
///
/// ```text
/// [0002] dispatch_task        agentId=architect, taskPrompt="Design the…"   +512tok  318.4ms
///          Δ __auto_reg_0 = "The design is…"
/// ```
///
/// Composes with other observers (e.g. the replay recorder): [attach] chains
/// any observer already installed, and [detach] restores it.
///
/// ```dart
/// final tracer = ExecutionTracer(runtime, sink: stdout.writeln)..attach();
/// await runtime.executeProgram(program);
/// tracer.detach();
/// ```
class ExecutionTracer {
  final VasterRuntime runtime;

  /// Where trace lines go (e.g. `stdout.writeln`, a log collector, a UI).
  final void Function(String line) sink;

  /// Whether to print register deltas beneath each instruction line.
  final bool showRegisterDeltas;

  /// Maximum rendered length for operand and register values.
  final int valueTruncation;

  RuntimeStepObserver? _previousObserver;

  /// Single stable closure instance so attach/detach identity checks hold
  /// (method tear-offs are not identity-stable in Dart). Bound in the
  /// constructor body — no lazy initialization.
  RuntimeStepObserver? _observer;

  Map<String, Object?> _previousRegisters = const {};
  int _previousTokens = 0;
  final Stopwatch _stepClock = Stopwatch();
  bool _attached = false;

  ExecutionTracer(
    this.runtime, {
    required this.sink,
    this.showRegisterDeltas = true,
    this.valueTruncation = 72,
  }) {
    _observer = _onStep;
  }

  /// Starts tracing. Any observer already installed keeps firing (chained
  /// after the tracer).
  /// Returns the observer this tracer displaced — including on the
  /// repeat-attach no-op path, where the ALREADY-displaced observer is
  /// the honest answer (a no-op that reads as "nothing was there" is the
  /// Rule 11 review flag; matches the replay recorder's attach).
  RuntimeStepObserver? attach() {
    if (_attached) return _previousObserver;
    _previousObserver = runtime.stepObserver;
    _previousRegisters = const {};
    _previousTokens = runtime.budget.consumedTokens;
    _stepClock
      ..reset()
      ..start();
    runtime.stepObserver = _observer;
    _attached = true;
    return _previousObserver;
  }

  /// Stops tracing and restores the previously installed observer.
  /// Detaches and returns the observer it RESTORED (null when it was not
  /// attached, or when nothing had been installed) — symmetric with
  /// [attach] and identical to the replay recorder's idiom.
  RuntimeStepObserver? detach() {
    if (!_attached) return null;
    final restored = _previousObserver;
    if (identical(runtime.stepObserver, _observer)) {
      runtime.stepObserver = restored;
    }
    _previousObserver = null;
    _stepClock.stop();
    _attached = false;
    return restored;
  }

  void _onStep(int pc, VasterInstruction instruction, Map<String, Object?> registers) {
    final elapsed = _stepClock.elapsed;
    _stepClock.reset();

    final tokens = runtime.budget.consumedTokens;
    final tokenDelta = tokens - _previousTokens;
    _previousTokens = tokens;

    final buffer = StringBuffer()
      ..write('[')
      ..write(pc.toString().padLeft(4, '0'))
      ..write('] ')
      ..write(instruction.opcode.name.padRight(20))
      ..write(' ')
      ..write(_formatOperands(instruction).padRight(44));
    if (tokenDelta > 0) buffer.write('  +${tokenDelta}tok');
    buffer.write('  ${_formatDuration(elapsed)}');
    sink(buffer.toString());

    if (showRegisterDeltas) {
      for (final entry in registers.entries) {
        final hadBefore = _previousRegisters.containsKey(entry.key);
        if (!hadBefore || _previousRegisters[entry.key] != entry.value) {
          sink('         Δ ${entry.key} = ${_formatValue(entry.value)}');
        }
      }
    }
    _previousRegisters = Map<String, Object?>.of(registers);

    _previousObserver?.call(pc, instruction, registers);
  }

  String _formatOperands(VasterInstruction instruction) {
    final json = instruction.toJson()..remove('opcode');
    if (json.isEmpty) return '';
    return json.entries.map((e) => '${e.key}=${_formatValue(e.value, quoteStrings: false)}').join(', ');
  }

  String _formatValue(Object? value, {bool quoteStrings = true}) {
    final rendered = switch (value) {
      null => 'null',
      String s => quoteStrings ? '"$s"' : s,
      Map() || List() => jsonEncode(value),
      _ => '$value',
    };
    return rendered.length <= valueTruncation ? rendered : '${rendered.substring(0, valueTruncation)}…';
  }

  String _formatDuration(Duration duration) {
    final us = duration.inMicroseconds;
    if (us < 1000) return '$usµs';
    return '${(us / 1000).toStringAsFixed(1)}ms';
  }
}
