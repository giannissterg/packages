# Vaster

> **Vaster** is an LLM virtual machine for Dart. Declarative multi-agent
> workflows compile to a serializable bytecode program that you can
> **statically verify before spending a token**, execute with
> **wire-accurate cost metering**, **suspend to a JSON checkpoint** at a
> human gate, **resume in a fresh process**, **replay deterministically**
> from a recorded tape, and **measure** with an eval harness.

## Status — v0.4.0, working and evidenced, pre-release

- **Not yet on pub.dev.** The API surface is still moving; use it from a
  clone of this repo (workspace resolution). Publishing is a 1.0 gate.
- **The core promise is demonstrated, not just claimed.** One genuinely
  useful workflow ran end-to-end on a real backend (claude CLI) with real
  money metered: statically checked, parked durably at an approval gate,
  process killed, resumed from JSON in a fresh VM, artifact written to
  disk. Transcript and findings: [docs/PROVE_IT.md](docs/PROVE_IT.md).
- **Zero-copy KV state is real and tested.** In-process llama.cpp
  inference over `dart:ffi` (`--backend llama`) with KV-cache state
  crossing process boundaries through shared-memory pages: a parked
  pipeline's pinned prefix resumes in a fresh process **without being
  re-decoded** (engine-measured), and a warm completion is
  token-identical to a cold one. Scope stated precisely in
  [docs/ZERO_COPY.md](docs/ZERO_COPY.md) — same-build state portability,
  one engine↔buffer copy, honest transport errors.
- **Honest limits, today:** most validation runs on fake models plus one
  paid recorded fixture and the small-model llama runs; token estimates
  are an uncalibrated `len/4`; static cost bounds assume API-shaped calls
  — agentic CLI backends exceed them (the runtime budget is the enforced
  defense, and calibration is on the roadmap).
- [ROADMAP.md](ROADMAP.md) defines 1.0 as **"the promises are contracts"**
  — everything this README claims, enforced by tests, bounded by
  `vaster check`, measured by `vaster eval`, stable across versions.

## What you get

- **Declarative composable AST** — Flutter-style trees (`Pipeline`,
  `Agent`, `Task`, `Prompt`, `Sequence`, …). Dataflow is explicit: a step
  binds its value with `output: Binding('name')`, later steps consume it
  via `${name}`; the compiler rejects reads without a dominating write.
- **Bounded agency** — `Decide` / `DecideLoop` let the model steer control
  flow, but only among statically declared destinations. `vaster audit`
  enumerates a program's complete decision surface without running it.
- **A real compilation target** — programs serialize to VBC binary or
  JSON; the ISA is language-agnostic by architectural rule
  ([rules.md](rules.md)), designed so a second-language runtime is
  possible (a conformance suite is a 1.0 gate — it does not exist yet).
- **Static verification (`vaster check`)** — definite assignment over the
  control-flow graph, worst-case call/token/dollar bounds from loop
  analysis plus pricing tables (honest about unbounded loops), and policy
  proofs: a forbidden file write is caught at its exact pc *before*
  execution, with `--max-cost` as a CI gate.
- **Durable execution** — `vaster run --checkpoint-dir` parks at a human
  gate (exit 3) writing a self-contained JSON checkpoint; `vaster resume`
  completes it in a fresh VM, meters continuing where they stood. Enforced
  by a checkpoint-at-every-instruction-boundary test suite.
- **Determinism** — `--record` captures a replay envelope (step journal +
  fingerprinted model tape); `--replay` re-executes with zero tokens and
  zero network; `vaster debug` is a time-travel debugger over any
  envelope (step forward/back, inspect registers, files, and context *as
  they were* at any step).
- **Real metering** — every model call flows through one metering
  pipeline charging wire-reported token and cost numbers (cache
  read/write breakdowns included); estimates are centralized and labeled;
  program-declared `BudgetScope`s are enforced machinery.
- **Eval harness (`vaster eval`)** — N hermetic trials, composable
  scorers, success rates with real metered cost per trial.
- **Coordination library** — `AgentTeam`, `FanOut` (map-reduce),
  `RefineLoop` (worker/critic), `Router`, `Resilient` (retry), `Produce`
  (schema-typed artifacts), plus a spec-driven-development workflow kit.
- **The rest of the machine** — transactional virtual filesystem with
  memory and disk mounts; policy engine; agents as actors (one agent, one
  session, one task at a time); sealed failure types throughout
  (`ExtractOutcome`, `AgentLifecycle`, `MachinePhase`); an event bus
  carrying full usage telemetry.
- **Model backends** — scripted fake (free, offline, deterministic),
  Claude API, Claude CLI, Google AI (Gemini), Gemini CLI, in-process
  llama.cpp over FFI with zero-copy KV frames (`llama`), and
  out-of-process sidecars (JSON over Unix sockets, or shared-memory
  rings for the llama engine).

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│              Declarative Composable AST                 │
│  (Pipeline, Agent, Decide, Knowledge, ApprovalGate, …)  │
└────────────────────────────┬────────────────────────────┘
                             │  BasicWorkflowCompiler
                             ▼
┌─────────────────────────────────────────────────────────┐        ┌──────────────────┐
│       Vaster ISA Program (.vbc binary / JSON)           │───────▶│  vaster check    │
│   serializable, auditable, statically verifiable        │        │  vaster audit    │
└────────────────────────────┬────────────────────────────┘        └──────────────────┘
                             │  VasterVMEngine + VasterRuntime
                             ▼
┌─────────────────────────────────────────────────────────┐        ┌──────────────────┐
│                  Vaster Runtime Engine                  │───────▶│  checkpoints     │
│  VFS · policy · budgets · metering · agents · events    │        │  replay tapes    │
└─────────────────────────────────────────────────────────┘        │  eval reports    │
                                                                   └──────────────────┘
```

The compiler frontend and the runtime are strictly separated: runtimes
execute only compiled programs and never see AST nodes
([rules.md](rules.md), Rule 1).

## Quickstart

Vaster is not on pub.dev yet — run it from the repo:

```bash
git clone https://github.com/giannissterg/packages.git vaster && cd vaster
dart pub get
dart run vaster_playground:example_01_hello_pipeline
```

The whole loop in one file (this exact code is kept compiling by
[`readme_quickstart_check.dart`](packages/vaster_playground/bin/readme_quickstart_check.dart)):

```dart
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  // 1. Define an agent role
  const architectRole = AgentRole(
    roleId: 'architect',
    name: 'Architect',
    title: 'Lead Software Architect',
    instruction: 'Expert in system design and clean code.',
  );

  // 2. Compose the declarative pipeline. `output:` binds a step's value;
  //    `${...}` / a Binding in a Template consumes it later. The pipeline's
  //    declared `result:` is what the host reads after halt.
  final pipeline = Pipeline(
    name: 'my_first_pipeline',
    result: const Binding('summary'),
    roles: const [architectRole],
    children: const [
      Agent(
        role: architectRole,
        child: Task(
          prompt: Template.text(
              'Analyze the project architecture and design the notes entity.'),
          output: Binding('design'),
        ),
      ),
      Prompt(
        Template(['Summarize this design in one paragraph:\n', Binding('design')]),
        output: Binding('summary'),
      ),
    ],
  );

  // 3. Compile the AST to a serializable ISA program
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  // 4. Bootstrap the VM with a model backend (fake = free and offline;
  //    swap in ClaudeCliVasterModel / GoogleAiVasterModel unchanged)
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel()),
  );

  // 5. Execute and read the declared result
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  print('status : ${state.status.name}');
  print('summary: ${state.registers[program.resultBinding]}');

  await vm.shutdown();
}
```

Next steps:

- **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)** — the 10-minute
  tour: compile an artifact, audit it, statically check it (including a
  proof that a hostile policy *would* fail), park it at a human gate, kill
  the process, resume it, and time-travel debug a recorded run.
- **[packages/vaster_playground](packages/vaster_playground)** — runnable
  examples, from the three-file on-ramp to full coordination showcases.

## The `vaster` CLI

```bash
dart pub global activate --source path packages/vaster_cli   # once; or use `dart run vaster_cli:vaster_cli …`
```

| Verb | What it does |
|---|---|
| `vaster run <prog>` | Execute a `.vbc`/`.json` program. `--backend fake\|claude-api\|claude-cli\|gemini\|gemini-cli\|rpc`, `--trace`, `--events`, `--record <envelope>`, `--replay <envelope>`, `--checkpoint-dir <dir>` (park at gates, **exit 3**) |
| `vaster resume <ckpt>` | Complete a parked run in a fresh VM. `--respond approve\|reject\|<text>`, `--checkpoint-dir` to re-park at the next gate |
| `vaster check <prog>` | Static verification: dominance, worst-case cost bound, policy proofs. `--policy`, `--model`, `--max-cost <usd>` (**exit 1** on breach) |
| `vaster audit <prog>` | Enumerate capabilities without running: file writes, tools, models, decision surface, human gates, budgets |
| `vaster eval <prog>` | N trials with scorers: success rate + real metered cost. `--trials`, `--contains`, `--regex`, `--json` |
| `vaster debug <envelope>` | Time-travel debugger over a recorded run: `seek`, `regs`, `diff`, `cat`, `vfs`, `ctx` |
| `vaster compile <prog>` | Analyze a serialized program and emit `.vbc` (AST pipelines compile via the library API — see quickstart) |
| `vaster disassemble <prog>` | ISA disassembly with opcode statistics |
| `vaster inspect <snapshot>` | Pretty-print a serialized continuation snapshot |
| `vaster serve` | Out-of-process model sidecar RPC server on a Unix socket |
| `vaster doctor` | Environment health checks |

A real session, verbatim (the fake backend costs nothing):

```text
$ dart run vaster_playground:example_02_ship_artifact
compiled 13 instructions → artifacts/examples/triage_note.vbc

$ vaster check artifacts/examples/triage_note.vbc --model claude-opus-5 --max-cost 0.5
  bound   : ≤1 model calls, ≤1053 tokens, ≤$0.0257
  findings: none — clean

$ vaster run artifacts/examples/triage_note.vbc --backend fake \
    --checkpoint-dir artifacts/examples/ckpts
── PARKED (durable) ── awaiting: File this triage note?   (exit 3)

$ vaster resume artifacts/examples/ckpts/triage_note_file_ticket.ckpt.json \
    --backend fake --respond approve
── RESUME COMPLETE ── status: halted
  output : filed
```

The same arc on a real paid backend, with the bug it found and what it
taught us: [docs/PROVE_IT.md](docs/PROVE_IT.md).

## Repository layout

~60 single-responsibility workspace packages under [`packages/`](packages).
The map, by layer: **frontend** `vaster_ast`, `vaster_domain`,
`vaster_compiler` · **ISA** `vaster_instruction` (VBC codec),
`vaster_dis` · **machine** `vaster_vm`, `vaster_vm_api`, `vaster_runtime`,
`vaster_machine_state` · **durability** `vaster_continuation`,
`vaster_checkpoint`, `vaster_replay`, `vaster_debug` · **verification &
measurement** `vaster_check`, `vaster_eval` · **subsystems** sessions,
context, agents, tools, sandboxes, filesystems, policy, budget, events,
metering, pricing, token estimation · **backends** `vaster_model_*` ·
**CLI** `vaster_cli` · **examples** `vaster_playground`. Architectural
law lives in [rules.md](rules.md).

## License

Vaster is released under the [MIT License](LICENSE).
