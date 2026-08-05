# vaster_playground

Runnable examples and end-to-end demos for the Vaster LLM virtual machine.
Everything here runs from the repo root with `dart run vaster_playground:<name>`;
unless a demo says otherwise, it uses the fake model backend — free,
offline, deterministic.

## Start here: the on-ramp (in order)

| Example | What it teaches |
|---|---|
| `example_01_hello_pipeline` | The whole loop in one page: declare a pipeline with a typed `Binding` wire, compile it, run it on a scripted fake model, read the declared result. |
| `example_02_ship_artifact` | Compile to a `.vbc` artifact the CLI owns: audit it, `vaster check` it, park it at a human gate (exit 3), resume it from JSON in a fresh process. Companion to [docs/GETTING_STARTED.md](../../docs/GETTING_STARTED.md). |
| `example_03_bounded_agency` | `Decide`: the model steers control flow, but only among statically declared paths — and the unchosen path provably never executes. |

The 10-minute walkthrough that strings these together:
[docs/GETTING_STARTED.md](../../docs/GETTING_STARTED.md).

## The catalog

Fake-backend demos (no keys, no cost):

| Demo | One line |
|---|---|
| `readme_quickstart_check` | Mirror of the root README quickstart — the API-drift guard; update both together. |
| `declarative_pipeline_example` | The declarative AST surface and typed context models, end to end. |
| `coordination_showcase_demo` | `AgentTeam`, `Knowledge`, `ContextBudget`, `Router`, `FanOut`, `RefineLoop`, `Produce` in one incident-response story. |
| `sdd_workflow_demo` | Spec-driven development as a phase tree: goal → spec.md → plan.md → review gate → parallel workstreams, coordinated through the VFS. |
| `decide_branching_demo` | `Decide` compiling to `DecideOp` with statically known destinations. |
| `decide_react_loop_demo` | ReAct-style `DecideLoop` with a `DecisionPolicy` provided via `Provider`. |
| `budget_composition_example` | Hierarchical `BudgetScope` quota reduction. |
| `hitl_hang_prevention_example` | Human approval gates and hang prevention. |
| `toolset_dynamic_agent_demo` | `ToolSet` scoping and the dynamic tool-calling loop. |
| `flutter_test_app_demo` | Flutter-style composable nodes writing through a real disk mount. |
| `software_engineering_dart_project_demo` | Generating a Dart package layout through composable nodes. |
| `compile_prove_it` | Compiles the `release_scribe` pipeline from the [prove-it milestone](../../docs/PROVE_IT.md) to `artifacts/prove_it/release_scribe.vbc`. |

Demos needing external processes or keys:

| Demo | Needs |
|---|---|
| `rpc_sidecar_model_demo` | A running `vaster serve` sidecar (Unix socket). |
| `real_google_ai_example` | `GEMINI_API_KEY` / `GOOGLE_AI_API_KEY` (or `--gemini` for the CLI backend). Spends real money. |
| `real_gemini_llm_coding_demo` | Same — an autonomous coding demo on live Gemini. |

## Tests

The package's `test/` directory holds the end-to-end suites that keep
these demos honest — including the launch-war-room stress program, the
durability suites, and `sdd_fidelity.replay.json`, a committed replay
fixture from a real paid run (replayed in tests at zero cost, asserting
byte-exact usage totals).
