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
