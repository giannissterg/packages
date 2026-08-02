import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'continuation_store_interface.dart';

/// Master manager contract for snapshot capture, storage persistence, and execution restoration.
abstract interface class ContinuationManager {
  /// Storage manager handling persistence.
  ContinuationStore get store;

  /// Captures a continuation snapshot linking execution state with session context and active model,
  /// saving it to [store].
  Future<VasterContinuation> capture(
    VasterRuntime runtime,
    String programName, {
    String? sessionId,
    ModelDescriptor? activeModelDescriptor,
  });

  /// Restores execution from a stored or provided [continuation] snapshot.
  Future<RuntimeState> restoreAndResume(
    VasterRuntime runtime,
    VasterContinuation continuation,
    VasterProgram program, {
    HumanInteractionResponse? humanResponse,
  });

  /// Retrieves a stored continuation snapshot by ID.
  Future<VasterContinuation?> getContinuation(String id);

  /// Lists all stored continuation snapshots.
  Future<List<VasterContinuation>> listContinuations();

  /// Deletes a stored continuation snapshot by ID.
  Future<bool> deleteContinuation(String id);
}

/// Standard implementation of [ContinuationManager] requiring a [ContinuationStore] (Rule 5).
class BasicContinuationManager implements ContinuationManager {
  @override
  final ContinuationStore store;

  BasicContinuationManager({required this.store});

  @override
  Future<VasterContinuation> capture(
    VasterRuntime runtime,
    String programName, {
    String? sessionId,
    ModelDescriptor? activeModelDescriptor,
  }) async {
    final state = runtime.state;
    final continuation = VasterContinuation(
      continuationId: 'cont_${DateTime.now().millisecondsSinceEpoch}',
      programName: programName,
      sessionId: sessionId,
      activeModelDescriptor: activeModelDescriptor,
      resumePc: state.pc,
      registers: Map<String, dynamic>.from(state.registers),
      pendingRequest: runtime.pendingHumanRequest,
    );
    await store.saveContinuation(continuation);
    return continuation;
  }

  @override
  Future<RuntimeState> restoreAndResume(
    VasterRuntime runtime,
    VasterContinuation continuation,
    VasterProgram program, {
    HumanInteractionResponse? humanResponse,
  }) async {
    return runtime.restoreAndResume(
      continuation.resumePc,
      program,
      registers: continuation.registers,
      pendingRequest: continuation.pendingRequest,
      humanResponse: humanResponse,
    );
  }

  @override
  Future<VasterContinuation?> getContinuation(String id) => store.loadContinuation(id);

  @override
  Future<List<VasterContinuation>> listContinuations() => store.listContinuations();

  @override
  Future<bool> deleteContinuation(String id) => store.deleteContinuation(id);
}
