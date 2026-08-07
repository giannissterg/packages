# AST Ergonomics Review

**Status:** draft for discussion · 2026-08-07
**Benchmark:** `packages/host/vaster_playground/bin/plan_external_codebase.dart` — the first
pipeline written against a real external codebase (the pocket_tasks dogfood run).
**Acceptance criterion:** the same pipeline in ≤ half the lines, with zero
escaped-dollar interpolation strings, written the way the docs would naturally
lead a newcomer to write it.

---

## 1. Motivation

The benchmark file is 173 lines. Decomposed:

| Lines | What | Nature |
|---|---|---|
| ~35 | arg parsing, fake-model script | example-specific, fine |
| ~30 | the pipeline tree | **7 AST frictions below** |
| ~75 | compile → bootstrap → runtime → recorder → execute → envelope → report → shutdown | **the missing `runApp` (F0)** |

Flutter's `main` is three lines because `runApp` owns binding init, tree attach,
and scheduling. Our equivalent does not exist, so every consumer hand-assembles
the same seven-step harness — the identical block now appears in
`run_command.dart`, two CLI test files, and the benchmark.

The subtler failure is in the tree itself. The typed dataflow tier —
`const spec = Binding('spec')` declared once, referenced in `output:` and
`Template` parts — **already exists, is documented as the intended style, and
raw `${` in a text part already draws a compiler warning.** Yet the benchmark
(written by an author with the entire codebase in context) used escaped-dollar
strings anyway, because the sugar-tier parameter it needed (`Specify.goal`) is
`String`-typed and *forces* the stringly path. The pit of success is missing:
the shortest way to write a pipeline is the tier the framework itself warns
about.

## 2. Target end state

```dart
// main: F0 — the facade owns the harness
void main(List<String> args) async {
  final report = await runPipeline(
    planFor(args.first),
    backend: ClaudeCliVasterModel(selectedModel: 'sonnet'),
    record: 'planning_run.replay.json',
  );
  print(report);
}

// the tree: F1–F7 applied
const pubspec = Binding('pubspec');
const mainDart = Binding('main_dart');

Pipeline planFor(String targetDir) {
  final review = Review(agent: reviewer);
  return Pipeline(
    name: 'external_codebase_plan',
    mounts: [Mount.disk('/project', targetDir)],
    result: review.output,
    children: [
      Sdd(root: '/project/planning', children: [
        ReadFile('/project/pubspec.yaml', output: pubspec),
        ReadFile('/project/lib/main.dart', output: mainDart),
        Specify(agent: architect, goal: Template([
          'Turn this freshly generated Flutter starter into "Pocket Tasks"…\n',
          '--- pubspec.yaml ---\n', pubspec,
          '\n--- lib/main.dart ---\n', mainDart,
        ])),
        Plan(agent: lead),
        review,
      ]),
    ],
  );
}
```

No escaped dollars, no `Provider<>` wrapper, no role double-declaration, no
magic result string, ~25-line `main`-plus-harness instead of ~105.

---

## 3. F0 — `runPipeline`: the missing `runApp` (harness, not AST)

**Current.** Every host writes: `BasicWorkflowCompiler().compile` →
`VasterVMEngine.bootstrap` → `VasterRuntime(vm:, policy:, budget:, scheduler:)`
→ `executeProgram` → shutdown; recording adds `ModelTape` +
`RecordingVasterModel` + `VasterExecutionRecorder` + `ReplayEnvelopeCodec` +
file write. The B2 ruling (required policy/budget/scheduler on `VasterRuntime`)
is correct for that layer — the caller owns the choice — but today "the caller"
is every consumer.

**Proposal.** A top-level `runPipeline` (the `runApp` idiom — a function, not a
static, per the statics rule) in the `vaster` umbrella package, which is
currently a pure re-export barrel and already depends on everything needed:

```dart
Future<RunReport> runPipeline(
  Pipeline pipeline, {
  required VasterModel backend,     // model choice stays explicit (Rule 5)
  ExecutionBudget? budget,          // default unlimited
  String? record,                   // owns tape/recorder/envelope when set
});
```

`RunReport` is a named report class (Rule R): final state, result value,
consumed tokens/cost, envelope path, artifact-friendly `toString()`. The
facade unwinds the VM on every path (owned-resources rule). HITL pauses in v1:
return the paused report and let the host decide (the CLI keeps its richer
park/resume loop).

**Migration:** additive; nothing changes for existing callers. The three
in-repo duplications migrate opportunistically.
**Risk:** low. The one design decision is what `RunReport` carries — keep v1
minimal, grow by need.

---

## 4. AST findings

### F1 — Sugar-node `String` params force the stringly tier *(compiler-behavior wave)*

**Current.** `Specify.goal` is `String`; `Review.of`, `Plan.from`, artifact
overrides are `String` paths. To interpolate a binding into a goal the consumer
writes `'\${pubspec}'` — which Dart silently mis-interpolates if the `\` is
forgotten, and which the compiler tier explicitly warns against in `Template`
parts.

**Proposal.** Every prompt-bearing sugar parameter accepts `Template`:
`goal: Template([...])` with `goal: Template.text('...')` for the pure-text
case. Keep a `String` overload only where content is genuinely literal.
Internally the SDD nodes already compose `Template`s; only the public parameter
types change.

**Migration:** breaking for SDD callers (`goal:` type change). Mechanical:
`goal: 'x'` → `goal: Template.text('x')`. Alternatively accept
`Object goal` (String | Template) and validate at build — rejected: rules
prefer typed params over runtime type sniffing. Take the break; the SDD kit is
young.
**Risk:** low-medium; touches every SDD example and fixture-guard test.

### F2 — `roles:` + `agent:` double declaration *(compiler-behavior wave)*

**Current.** `Pipeline(roles: [architect, lead, reviewer], …)` AND each phase
names its agent. Forgetting a role in the list is a runtime provisioning
failure the tree could have prevented — the information is already in the tree.

**Proposal.** The pipeline build walks its subtree and collects every distinct
`AgentRole` referenced by an `agent:` slot (identity-distinct, name-deduped
with a conflict diagnostic), emitting provision headers automatically.
`roles:` stays for roles used only via `agentId:` string reference — with the
doc rewritten to say so ("declare only what the tree cannot see").

**Migration:** non-breaking (explicit `roles:` keeps working; collected roles
merge). The Pipeline.build doc already notes roles are "provisioning, not
scoping" — collection preserves that.
**Risk:** medium: needs a tree-walk before lowering; `agentId:`-only references
(cross-scope, Router targets) must keep working, hence keeping the param.

### F3 — `AgentRole` demands three names *(additive-sugar wave)*

**Current.** `roleId` + `name` + `title` + `instruction` — four required
fields; the benchmark's three roles cost 21 lines. Consumers think "a persona
with a prompt."

**Proposal.** `AgentRole('architect', instruction: '…')` — positional
`roleId`; `name` defaults to a title-cased `roleId`, `title` defaults to
`name`. Existing named-arg form stays valid.

**Migration:** non-breaking (add positional + defaults; keep the full ctor).
**Risk:** low. `toJson` shape unchanged (defaults serialize as before).

### F4 — `Template.text(...)` wrapper on literal paths *(additive-sugar wave)*

**Current.** `ReadFile(path: Template.text('/project/pubspec.yaml'))` — a
constant path costs a wrapper. Same for `WriteFile.path`.

**Proposal.** Positional `String` convenience: `ReadFile('/project/pubspec.yaml',
output: pubspec)` wrapping internally; `ReadFile.template(path: Template(...))`
(or the existing named form) for dynamic paths.

**Migration:** non-breaking if added as new positional ctor alongside the
named one; consider deprecating the wrapped form for literals later.
**Risk:** low.

### F5 — `Provider<SddConventions>` wrapper for one setting *(scope-sugar wave)*

**Current.** Overriding the artifact root costs a wrapper node, a generic
parameter, and two indent levels. The inherited-value mechanism (the
`InheritedWidget` analogue) is right; the spelling is not.

**Proposal.** An `Sdd` scope composable: `Sdd(root: '/project/planning',
children: [...])` that expands to the Provider internally. Generalization
(`Pipeline(providers: [...])`) deferred — one honest sugar node now, the
general mechanism stays `Provider` for everything else.

**Migration:** additive.
**Risk:** low.

### F6 — Two mount mechanisms, one verbose value type *(additive-sugar wave)*

**Current.** `Pipeline.mounts: [StorageMount(mountPrefix: '/project', type:
StorageMountType.disk, diskPath: targetDir)]` — three named args for the
common case; AND a separate `Mount` scope node exists that still takes a
`StorageMount` inside. Two spellings, both verbose.

**Proposal.** Factory constructors on the value type:
`StorageMount.disk('/project', targetDir)` / `StorageMount.memory('/scratch')`,
surfaced in the AST barrel as `Mount.disk(...)`-style aliases if we keep the
node. Decide the node's fate in review: `Pipeline.mounts` for provisioning,
`Mount` node only if subtree-scoped mounts have a real consumer — otherwise
deprecate the node.

**Migration:** additive ctors; node deprecation (if chosen) is a separate
breaking step.
**Risk:** low.

### F7 — `result:` couples to a node's *internal* default binding *(compiler-behavior wave)*

**Current.** `result: const Binding('review')` works only because the consumer
knows `Review`'s default output binding is named `review` — a magic string
reaching into another node's internals; a rename inside the SDD kit breaks
consumers silently at compile (or worse, rebinds to nothing and fails the
dataflow check with an unrelated-looking error).

**Proposal.** Output-producing composables expose their binding:
`final review = Review(agent: reviewer); … result: review.output`. Node
identity carries the wire; the string never appears in consumer code. The
default (`result:` omitted) could additionally mean "the last child's declared
output" — decide in review whether that implicitness is worth it (leaning no:
explicit `result:` is one line and self-documenting).

**Migration:** additive (`output` getters on Specify/Plan/Review/Task sugar
already exist as params; expose the *effective* binding, namespaced the way
`build` would mint it — needs care with `BindingScope` namespacing, which is
context-dependent: the getter may need to be honest that it reports the
unscoped default).
**Risk:** medium — the namespacing caveat is real; a naive getter that lies
under `BindingScope` is worse than the string. May need `result:` to accept
the node itself and resolve during build, where context exists.

---

## 5. Sequencing

| Wave | Items | Nature | Gate |
|---|---|---|---|
| **W0** | F0 `runPipeline` + `RunReport` | additive, no AST churn | benchmark `main` ≤ ~25 lines; three in-repo harness duplications migrated |
| **W1** | F3, F4, F6 | additive ctors/defaults | no existing tree breaks; benchmark tree adopts |
| **W2** | F1, F2, F7 | compiler-behavior + one type break | fixture-drift guards updated deliberately; `vaster check` still proves the same program |
| **W3** | F5 (`Sdd` scope) | additive sugar | benchmark loses its `Provider<>` wrapper |

Every wave: `dart analyze --fatal-infos`, full sweep, Rule 11 ratchet, and the
benchmark file re-measured against the acceptance criterion. W2 changes
compiled instruction streams only where F2 adds collected provision headers —
replay-equivalence of existing recordings must be checked against the
committed fixture before landing.

## 6. Open questions

1. **F2 collection scope:** collect from the whole subtree or only direct
   children? (Subtree, presumably — Router/FanOut nest agents deep.)
2. **F7 namespacing:** can `output` getters be honest under `BindingScope`,
   or must `result:` learn to accept a node and resolve at build time?
3. **F1 break vs. overload:** take the `goal:` type break now (kit is young)
   or carry `Object` params temporarily? (Doc recommends the break.)
4. **`Mount` node fate** (F6): does subtree-scoped mounting have a consumer?
5. Does `RunReport` (F0) fold in artifact listing (files written under the
   pipeline's mounts), or is that the host's business?

## 7. Rules alignment

- **Rule 5 / B2:** F0 keeps model choice explicit and required; canonical
  defaults live in ONE host composer, not scattered nullable params.
- **Rule R (named types):** `RunReport` instead of a record; findings F1/F7
  remove stringly cross-node contracts (Rule 11's "strings carry data, never
  semantics" — a binding name a consumer must know is a semantic string).
- **Statics rule:** `runPipeline` is a top-level function (the `runApp` idiom),
  not behavior on a static.
- **Rule 63:** W0 adds no dependencies (the umbrella package already depends
  on every needed package); later waves add none.
