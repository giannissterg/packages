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
  setQuota('set_quota'),
  jump('jump'),
  jumpIf('jump_if'),
  setRegister('set_register'),
  jsonExtract('json_extract'),
  concatRegister('concat_register'),
  beginTransaction('begin_transaction'),
  commit('commit'),
  rollback('rollback'),
  selectModel('select_model'),
  createSession('create_session'),
  setSession('set_session'),
  checkPolicy('check_policy'),
  yieldHumanInteraction('yield_human_interaction'),
  call('call'),
  returnSubroutine('return_subroutine'),
  halt('halt');

  final String name;

  const InstructionOpcode(this.name);

  static InstructionOpcode parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final op in InstructionOpcode.values) {
      if (op.name == lower) return op;
    }
    return InstructionOpcode.prompt;
  }

  @override
  String toString() => name;
}
