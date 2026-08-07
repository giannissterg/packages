## Unreleased

- `sdlc_cycle` — the FULL engineering cycle in one pipeline: PM writes a
  PRD, tech manager writes a design and a schema'd JSON backlog
  (`Produce`), an agent PICKS the next actionable ticket, an engineer
  implements it (dynamic paths from the ticket), then three-tier
  testing — unit (generated tests), DEV (the pipeline runs real
  `flutter analyze`+`flutter test` through a process sandbox and a model
  judges the output via `Verify`), QA (acceptance-criteria review) —
  and the backlog records the outcome. The live run's QA tier CAUGHT a
  real downstream failure (schema-less claude-cli pick → empty
  path bindings → files at literal ${path}) and correctly FAILED the
  ticket, auto-marking it blocked: bad work does not ship. Fixes
  shipped from the finding: RunReport surfaces warnings; mountSandbox
  routes by language; the pick step self-defends its JSON.

- `revise_from_review` — dogfood phase three: the framework CLOSES ITS
  OWN REVIEW LOOP. Author applies the prior code review's blocking
  fixes to the generated model + tests, then `Review(revise: Author(…))`
  re-reviews with the self-revising loop live (maxRounds 2). The live
  run APPROVED on round one; externally verified: flutter analyze
  clean, 24/24 tests pass incl. 100-id uniqueness, all fixes landed
  without regressing the _restore contract.

- `stress_lab` — eleven adversarial probes against the framework's
  edges (budget trips, program quotas, fallback chains, injected model
  faults, unresolved interpolation, trap recovery, decide-loop
  exhaustion, Provider+Builder grounding, Author discipline,
  transaction rollback), each encoding the LEARNED contract: host
  budgets exhaust to timedOut and charge post-call; program quotas
  trap; agent failures write the sealed outcome register AND fail-stop.

- `implement_from_plan` — dogfood phase two: the framework WRITES
  CODE into another codebase. Reads the target's committed plan.md AND
  review.md, implements the task model + unit tests as real files
  (raw-source discipline, budget-capped, recorded), reviews its own
  output. Verified externally: flutter analyze clean, all generated
  tests pass, the prior review's blocking fixes landed in the code.

- `example_04_bring_your_own_model` — the BYO-model + zero-cost-replay
  story: a local function standing in for "your existing SDK call"
  wrapped via `VasterModel.fromTextHandler`, run through `runPipeline`
  with `record:`, then the same pipeline replayed from the envelope
  with zero live calls.

## 0.5.0

- `plan_external_codebase` — dogfood bin: disk-mount ANOTHER codebase at
  `/project`, read its real files into bindings, and run the SDD kit
  (Specify → Plan → Review) grounded in that content; artifacts land in
  `<target>/planning/` and the run records to a replay envelope.
  `--backend fake` (default) or `claude-cli`. (Adds the
  `vaster_model_claude_cli` workspace dep, mirroring the existing
  `vaster_model_google_ai` real-backend example dep.)

- Curated on-ramp examples: `example_01_hello_pipeline` (declare →
  compile → run → read the declared result), `example_02_ship_artifact`
  (emit a gated `.vbc` for the CLI audit/check/park/resume arc),
  `example_03_bounded_agency` (`Decide` with a provably unexecuted
  unchosen path). Companions to the new `docs/GETTING_STARTED.md`.
- Real package README: the on-ramp plus the full demo catalog, replacing
  the Dart template stub.
- `readme_quickstart_check` now reads the pipeline's declared result via
  `program.resultBinding`, mirroring the rewritten root README quickstart.

## 0.2.0

- Initial version.
