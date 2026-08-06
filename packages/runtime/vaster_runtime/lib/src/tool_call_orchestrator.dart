import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'effect_ledger.dart';
import 'policy_guard.dart';


/// Orchestrates the model ↔ tool conversation for one prompt.
///
/// This is model-orchestration concern, not instruction dispatch — extracting
/// it keeps [VasterRuntime] a pure fetch-decode-dispatch loop. The
/// orchestrator owns its collaborators at construction — and holds exactly
/// the VM facet its job needs ([ToolLoopHost]: prompt funnel, tool symbol
/// table, event bus, VFS), so its type says "tool loop", not "whole VM".
/// Everything passed to [resolve] is genuinely per-invocation state (the
/// active model, cache hints, and program-registered toolset all change as
/// the program executes).
///
/// Tool calls dispatch through the VM's [ToolManager] symbol table — any
/// registered tool (sandbox bridges, function tools, toolsets) is callable by
/// the model. `write_file` / `read_file` remain as built-in VFS syscalls when
/// no registered tool overrides them. Every result returns to the model as a
/// typed `tool_result` part in a full transcript continuation — never
/// flattened to prose.
final class ToolCallOrchestrator {
  /// The tool loop's VM facet — turns, tools, telemetry, VFS; nothing else.
  final ToolLoopHost host;

  /// The runtime's shared metering pipeline (host budget + program quota).
  final ModelCallMeter meter;

  /// Attribution fallback when no active model is passed and the response
  /// carries no serving-model stamp.
  final VasterModel defaultModel;

  /// Kept alongside [meter] for the one thing metering doesn't cover:
  /// recording tool-call counts against the program quota.
  final ResourceTracker quotaTracker;

  final PolicyGuard guard;

  /// Maximum model turns in one tool-calling loop (runaway guard).
  final int maxIterations;

  /// The runtime's idempotency ledger (REL-P4): inside an effect scope,
  /// non-VFS tool calls execute-or-replay through it so a retry attempt
  /// never re-performs a side effect that already happened. VFS syscalls
  /// bypass it — the transaction machinery owns compensable effects.
  final EffectLedger ledger;

  const ToolCallOrchestrator({
    required this.host,
    required this.meter,
    required this.defaultModel,
    required this.quotaTracker,
    required this.guard,
    required this.maxIterations,
    required this.ledger,
  });

  /// Runs the tool-calling loop until the model stops requesting tools (or
  /// [maxIterations] is reached) and returns the final response.
  Future<ModelResponse> resolve({
    required String prompt,
    required ModelResponse initialResponse,
    required List<ToolDefinition> programToolSet,
    VasterModel? model,
    List<ContextCacheHint> cacheHints = const [],
  }) async {
    var response = initialResponse;
    final transcript = <ChatMessage>[ChatMessage.user(prompt)];

    // Linked symbol table: program-registered defs + VM tool registry.
    final toolDefinitions = {
      for (final def in host.toolManager.compiledDefinitions) def.name: def,
      for (final def in programToolSet) def.name: def,
    }.values.toList();

    var iterations = 0;
    while (response.functionCalls.isNotEmpty && iterations < maxIterations) {
      iterations++;

      // Echo the assistant turn (with its tool_use parts), then execute every
      // call in the turn and answer them all in a single tool message.
      transcript.add(response.message);
      final results = <ContentPart>[];
      for (final call in response.functionCalls) {
        guard.check(PolicyAction.toolCall, call.name);
        host.eventBus.publish(ToolCalledEvent(
          eventId: 'evt_tool_call_${call.callId}',
          callId: call.callId,
          toolName: call.name,
          arguments: call.arguments,
        ));
        // VFS syscalls are compensable (the transaction machinery rolls
        // them back) so they always re-execute; everything else goes
        // through the ledger — inside an effect scope, a retried call
        // replays its recorded result instead of re-performing the effect.
        final isVfsSyscall = call.name == VfsSyscalls.writeFileName ||
            call.name == VfsSyscalls.readFileName;
        final toolClock = Stopwatch()..start();
        final outcome = isVfsSyscall
            ? (result: await _dispatchToolCall(call), replayed: false)
            : await ledger.executeOrReplay(
                name: call.name,
                arguments: call.arguments,
                execute: () => _dispatchToolCall(call),
              );
        toolClock.stop();
        if (outcome.replayed) {
          host.eventBus.publish(ToolCallReplayedEvent(
            eventId: 'evt_tool_replay_${call.callId}',
            callId: call.callId,
            toolName: call.name,
          ));
        } else {
          // Replays perform no work: only real executions count against
          // the program's tool-call quota.
          quotaTracker.recordToolCall();
        }
        host.eventBus.publish(ToolFinishedEvent(
          eventId: 'evt_tool_done_${call.callId}',
          callId: call.callId,
          toolName: call.name,
          isError: outcome.result.containsKey('error'),
          executionDuration: toolClock.elapsed,
        ));
        results.add(FunctionResponsePart(
          callId: call.callId,
          name: call.name,
          response: outcome.result,
        ));
      }
      transcript.add(ChatMessage(role: Role.tool, parts: results));

      response = await host.promptWithHistory(
        transcript,
        model: model,
        tools: toolDefinitions,
        cacheHints: cacheHints,
      );
      // Each loop turn re-sends the whole transcript — the estimate must
      // count that input side, not just the reply.
      meter.charge(
        usage: response.usage.totalTokenCount > 0
            ? response.usage
            : UsageMetadata(
                promptTokenCount: TokenEstimate.forMessages(transcript),
                candidatesTokenCount: TokenEstimate.forText(response.text),
              ),
        modelName:
            response.servedBy ?? (model ?? defaultModel).modelName,
        callSite: 'isa_tool_loop',
      );
    }
    return response;
  }

  /// Dispatches one tool call. Built-in VFS syscalls take precedence — they
  /// carry the runtime's policy checks (fileWrite/fileRead), which registered
  /// handlers cannot enforce. Everything else resolves through the VM's
  /// [ToolManager] symbol table; unlinked names return a typed error payload
  /// the model can recover from.
  Future<Map<String, dynamic>> _dispatchToolCall(FunctionCallPart call) async {
    try {
      // 1. Built-in policy-gated VFS syscalls (must win over registrations so
      //    the ExecutionPolicy cannot be bypassed via the tool table). The
      //    handler itself is the shared [VfsSyscalls] implementation — only
      //    the policy gate lives here.
      switch (call.name) {
        case VfsSyscalls.writeFileName:
          guard.check(
              PolicyAction.fileWrite, call.arguments['path']?.toString() ?? '');
          return await VfsSyscalls.writeFile(host.fileSystemManager, call.arguments);
        case VfsSyscalls.readFileName:
          guard.check(
              PolicyAction.fileRead, call.arguments['path']?.toString() ?? '');
          return await VfsSyscalls.readFile(host.fileSystemManager, call.arguments);
      }

      // 2. Symbol table — the linked tool registry.
      if (host.toolManager.getTool(call.name) != null) {
        final result = await host.toolManager.executeCall(call);
        return result.isError
            ? {'error': result.errorDetails ?? 'Tool execution failed.'}
            : result.response;
      }

      // 3. Unlinked symbol.
      return {
        'error':
            'Unknown tool "${call.name}" — not registered in the VM tool table.',
      };
    } on PolicyViolationException {
      rethrow; // security trap — uncatchable, never fed back to the model
    } on StateError catch (e) {
      return {'error': e.message};
    } catch (e) {
      return {'error': 'Tool execution error: $e'};
    }
  }
}
