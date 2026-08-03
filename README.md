# Vaster LLM Virtual Machine 🚀

> **Vaster** is a high-performance LLM Virtual Machine & Workflow Compiler framework for Dart. It compiles declarative multi-agent workflows into serializable Instruction Set Architecture (ISA) bytecode, executing them with nanosecond-level VM dispatch, atomic virtual filesystem transactions, continuations, and out-of-process model RPC sidecars.

---

## Key Features

- 🏗 **Declarative Composable AST**: Flutter-style functional trees for multi-agent workflows. Value flow is declarative — every producing node binds an `output:` name and later steps consume it with `${name}` interpolation, checked at compile time.
- 🤖 **Bounded Agency (`Decide`/`DecideLoop`)**: the model steers control flow, but only among statically known destinations — analyzers can enumerate a program's full decision surface.
- 🧩 **Coordination Library**: `AgentTeam`, `FanOut` (map-reduce), `RefineLoop` (worker/critic), `Router` (model-steered dispatch), `Resilient` (retry), `Produce` (schema-typed artifacts).
- 📋 **SDD Workflow Kit**: spec-driven development as a phase tree — `Clarify → Specify → Plan → Review → Implement → Verify` — with markdown artifacts (spec.md, plan.md, …) in the VFS as the coordination medium between agents.
- 🧠 **Declarative Context (`Knowledge`/`ContextBudget`)**: declare what the model knows as a scope; the region's lifetime is structural (mounts on entry, unmounts on exit).
- ⚡ **ISA Bytecode Compiler (`vaster_compiler`)**: Compiles high-level AST trees into flat, serializable bytecode programs (`VasterProgram`), decoupled from runtime execution.
- 🔍 **Bytecode Disassembler (`vaster_dis`)**: Inspect compiled ISA bytecode, instruction counts, opcode statistics, and jump targets.
- 💾 **Durable Continuations (`vaster_continuation`)**: Pause and resume execution anywhere (e.g. at Human Approval Gates) with zero-copy JSON snapshots (`VasterContinuation`).
- 🔌 **Out-of-Process Model Sidecar RPC (`vaster_model_rpc`)**: Connect local or remote model servers (Gemini 2.0 Flash, Gemini CLI, Ollama, C++ models) over high-speed Unix Domain Sockets (`/tmp/vaster_model.sock`).
- 📂 **Transactional Virtual Filesystem (`vaster_filesystem`)**: Atomic transaction blocks (`BeginTransactionOp`, `CommitOp`, `RollbackOp`) with memory or local disk mounting.
- 🛠 **`vaster` CLI Tool (`vaster_cli`)**: Run, disassemble, inspect, serve, and diagnose Vaster VM environments directly from your terminal.

---

## System Architecture

```text
┌─────────────────────────────────────────────────────────┐
│              Declarative Composable AST                 │
│  (Pipeline, Agent, Task, Decide, Knowledge, SDD kit, …) │
└────────────────────────────┬────────────────────────────┘
                             │  BasicWorkflowCompiler
                             ▼
┌─────────────────────────────────────────────────────────┐
│               Vaster ISA Bytecode Program               │
│  [CreateAgent, CreateSession, DispatchTask, WriteFile]  │
└────────────────────────────┬────────────────────────────┘
                             │  VasterVMEngine + VasterRuntime
                             ▼
┌─────────────────────────────────────────────────────────┐
│                  Vaster Runtime Engine                  │
│    (Virtual Filesystem · Policy Engine · Budget · RPC)   │
└─────────────────────────────────────────────────────────┘
```

---

## Quickstart

Add `vaster` to your `pubspec.yaml`:

```yaml
dependencies:
  vaster: ^0.0.1
```

### 1. Build and Run a Pipeline in 30 Seconds

```dart
import 'package:vaster/vaster.dart';

void main() async {
  // 1. Define LLM Agent Roles
  const architectRole = AgentRole(
    roleId: 'architect',
    name: 'Architect',
    title: 'Lead Software Architect',
    instruction: 'Expert in system design and clean code.',
  );

  // 2. Compose the declarative AST pipeline. `output:` binds a step's
  //    value; `${...}` interpolates it into later prompts at runtime.
  final pipeline = Pipeline(
    name: 'my_first_pipeline',
    roles: const [architectRole],
    children: const [
      Agent(
        role: architectRole,
        child: Task(
          prompt: 'Analyze the project architecture and design the notes entity.',
          output: 'design',
        ),
      ),
      Prompt('Summarize this design in one paragraph:\n\${design}'),
      Output(),
    ],
  );

  // 3. Compile AST to ISA Bytecode
  final compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  // 4. Bootstrap Vaster VM Engine with Model Backend
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel()),
  );

  // 5. Execute Pipeline in Vaster Runtime
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  print('Pipeline execution status: ${state.status.name}');

  await vm.shutdown();
}
```

---

## The `vaster` CLI Tool

Vaster includes a command-line interface for running and inspecting VM workflows:

```bash
# Run system diagnostics and environment health check
vaster doctor

# Compile a serialized program: static analysis + .vbc binary emission
vaster compile pipelines/my_pipeline.json

# Run a compiled program (.vbc/.json) with a live execution trace,
# an event stream, and a time-travel replay journal
vaster run my_pipeline.vbc --trace --events --record journal.json

# Disassemble compiled ISA bytecode
vaster disassemble my_pipeline.vbc

# Start the out-of-process Model Service RPC Sidecar Server
vaster serve --socket /tmp/vaster_model.sock

# Inspect a serialized VasterContinuation JSON snapshot
vaster inspect snapshots/continuation_01.json
```

---

## Out-of-Process Model Service RPC Protocol

Vaster supports out-of-process sidecar model invocation over Unix Domain Sockets:

```dart
// Connect Vaster VM to an out-of-process Model Sidecar Server
final rpcModel = RpcVasterModel(
  socketPath: '/tmp/vaster_model.sock',
);

final vm = await VasterVMEngine.bootstrap(
  config: VMConfig(defaultModel: rpcModel),
);
```

---

## License

Vaster is released under the [MIT License](LICENSE).
