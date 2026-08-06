/// Strongly-typed enum of Vaster Instruction Set Architecture (ISA) opcodes.
enum InstructionOpcode {
  prompt('prompt'),
  mountFs('mount_fs'),
  writeFile('write_file'),
  readFile('read_file'),
  registerSandbox('register_sandbox'),
  execSandbox('exec_sandbox'),
  createAgent('create_agent'),
  dispatchAgentTask('dispatch_agent_task'),
  dispatchParallelTasks('dispatch_parallel_tasks'),
  sendMessage('send_message'),
  popMessage('pop_message'),
  forkSession('fork_session'),
  pinContext('pin_context'),
  addContext('add_context'),
  evictContext('evict_context'),
  unpinContext('unpin_context'),
  setContextPolicy('set_context_policy'),
  compressContext('compress_context'),
  incrementRegister('increment_register'),
  compareRegister('compare_register'),
  pushErrorHandler('push_error_handler'),
  popErrorHandler('pop_error_handler'),
  registerToolSet('register_tool_set'),
  setQuota('set_quota'),
  jump('jump'),
  jumpIf('jump_if'),
  setRegister('set_register'),
  jsonExtract('json_extract'),
  concatRegister('concat_register'),
  beginTransaction('begin_transaction'),
  commit('commit'),
  rollback('rollback'),

  /// Effect-scope brackets (REL-P4): within a scope, non-compensable tool
  /// calls are recorded so a retry attempt replays results instead of
  /// re-executing side effects.
  pushEffectScope('push_effect_scope'),
  popEffectScope('pop_effect_scope'),
  markEffectRetry('mark_effect_retry'),
  selectModel('select_model'),
  createSession('create_session'),
  setSession('set_session'),
  checkPolicy('check_policy'),
  yieldHumanInteraction('yield_human_interaction'),
  call('call'),
  returnSubroutine('return_subroutine'),

  /// Model-steered branch among statically-known labeled targets.
  decide('decide'),
  halt('halt');

  final String name;

  const InstructionOpcode(this.name);

  /// Parses an opcode name, throwing [FormatException] on unknown names.
  ///
  /// An unknown name means the program was produced by a newer (or skewed)
  /// toolchain — silently decoding it as any other opcode would corrupt the
  /// program, so version skew must fail loudly. Callers decoding VBC bytes
  /// surface this as a [VbcDecodeException] via [VbcCodec.decode].
  static InstructionOpcode parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final op in InstructionOpcode.values) {
      if (op.name == lower) return op;
    }
    throw FormatException(
        'Unknown ISA opcode "$value" — the program was likely produced by a '
        'newer toolchain than this runtime supports.');
  }

  @override
  String toString() => name;
}
