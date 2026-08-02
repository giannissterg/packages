# Vaster LLM Virtual Machine Ecosystem — Core Architectural Rules

## 1. Scope Boundary: Language Coupling & Independence
- **AST Frontend (`vaster_ast`, `vaster_domain`, `vaster_compiler`)**: It is **completely acceptable** for the AST compiler frontend to depend on Dart and Dart VM features (e.g., Dart generic classes, Flutter-style `ComposableNode`, `BuildContext`, `Provider<T>`, and exhaustive Dart `sealed class` pattern matching). AST construction and compilation is a host-side developer frontend API.
- **CRITICAL BOUNDARY — Compiler Frontend Isolation**: The compiler frontend packages — `vaster_ast`, `vaster_domain`, and `vaster_compiler` — **MUST NEVER** be imported by or added as a dependency (production or dev) to any runtime, ISA, VM, continuation, or backend package (`vaster_instruction`, `vaster_runtime`, `vaster_vm`, `vaster_continuation`, `vaster_continuation_manager`, `vaster_model_*`, `vaster_filesystem_*`, `vaster_sandbox_*`, `vaster_agent_*`, `vaster_session_*`, `vaster_context_*`, `vaster_resources`, `vaster_events`, `vaster_policy`, `vaster_policy_engine`, `vaster_budget`, `vaster_scheduler`, `vaster_tool`, `vaster_tool_manager`). All runtime engines operate exclusively on compiled `VasterProgram` bytecode — they must never reference AST nodes, domain spec types, or compiler classes. Tests and examples in runtime packages must construct `VasterProgram` instances directly using low-level ISA instructions from `vaster_instruction`.
- **Pure Serializability**: The target bytecode ISA (`VasterProgram`, `VasterInstruction`), domain specifications (`PipelineSpec`, `AgentRole`), and model descriptors (`ModelDescriptor`) must remain 100% language-agnostic and JSON-serializable so the compiled program can be executed on runtimes implemented in any host language (e.g., Rust, Go, C++, Python).
- **Handles & Descriptors**: Execution engines and ISA opcodes must operate strictly via descriptors, handles, primitive strings, integer registers, and JSON payloads rather than host language object references.

## 2. Aggressive Composition Over Inheritance
- **Composition First**: Always prefer **aggressive composition over inheritance** across all package abstractions.
- **Composable AST Nodes**: High-level workflow constructs must use composition (`ComposableNode.build(BuildContext context)`) to assemble modular sub-trees rather than deep object inheritance hierarchies.
- **Subsystem Decoupling**: Build complex VM engines by composing decoupled, single-responsibility subsystem managers (`SessionManager`, `ContextManager`, `FileSystemManager`, `ToolManager`, `SandboxManager`, `AgentManager`, `ModelRegistry`, `RuntimeEventBus`, `AgentMessagingHub`, `ResourceTracker`) rather than monolithic superclasses.

## 3. Package Purity & Minimal Core Footprint
- **Lean Core Runtime**: Keep core execution packages (especially `vaster_runtime`, `vaster_instruction`, and `vaster_vm`) clean, lean, and unpolluted by peripheral features.
- **Dedicated Subsystem Packages**: New subsystem capabilities (such as continuation persistence, disassembly, sandboxing, models, and manager components) **must be created as dedicated, single-responsibility packages** (e.g. `vaster_continuation`, `vaster_dis`, `vaster_sandbox_process`, `vaster_model_google_ai`). Do not bloat core execution runtimes with optional features.

## 4. The LLM VM Execution Triad (Model, Session, Continuation)
- **Model = Processor**: `VasterModel` is the non-deterministic LLM compute unit. It consumes structured prompts/messages and tool definitions to produce outputs.
- **Session = Memory & Context Heap**: `VasterSession` maintains conversational turn history, system instructions, pinned context regions, tool schemas, and token tracking. It can be forked (`ForkSessionOp`) to branch memory trees.
- **Continuation = Execution Snapshot**: `VasterContinuation` captures the frozen state of ISA bytecode execution (`resumePc`, `registers`, `callStack`, `pendingRequest`) referencing an active `sessionId`. It allows long-running or pauseable workflows to yield without blocking host OS threads and resume safely across server reboots.

## 5. Strict Construction-Time Ownership (Runtime & Backend Packages)

This rule applies to all runtime and backend packages (`vaster_runtime`, `vaster_vm`, `vaster_agent_*`, `vaster_session_*`, `vaster_context_*`, `vaster_model_*`, `vaster_filesystem_*`, `vaster_sandbox_*`, `vaster_tool_*`, `vaster_resources`).

- **No Optional Dependencies on Method Signatures**: If a component *owns* a dependency (e.g. a `ResourceTracker`, `ToolManager`, or `ContextManager`), that dependency **must be a required constructor parameter**, never an optional parameter on a method. Optional parameters on method signatures signal unclear ownership and are forbidden for owned concerns.
- **Required Over Nullable**: Prefer `required T field` over `T? field`. If a component always needs a concern, make it required. If truly unlimited/no-op behaviour is needed, provide a canonical default instance (e.g. `ResourceTracker(quota: ResourceQuota.unlimited)`) rather than accepting `null`.
- **Behavioral Configuration Belongs in Descriptors**: Behavioral limits and policies (e.g. `maxToolCallLoops`, `allowedToolNames`) belong in the component's **descriptor** (e.g. `AgentDescriptor`), not as per-invocation parameters.
- **Per-Invocation Exception — `CancellationToken` Only**: The sole legitimate optional per-invocation parameter is `CancellationToken?`. Cancellation is inherently tied to a specific call, not to the component's lifetime, and cannot be set at construction time.
- **Ownership Table**: Every parameter must have an unambiguous owner. When adding a new parameter, answer: *"Does this belong to the component's identity/config (→ constructor or descriptor), or is it truly per-call (→ method parameter only if CancellationToken-like)?"*

## 6. Conceptual Isolation Matrix (Concept Unawareness Rules)

To prevent concept conflation and architectural coupling across package boundaries, the following one-line concept unawareness rules are strictly enforced:

1. **AST Nodes & Frontend Constructs (`vaster_ast`, `vaster_domain`)**: Must NOT know about ISA bytecode execution, registers (`RegisterFile`), call stacks (`CallStack`), program counters (`_pc`), or low-level VM execution managers.
2. **ISA Bytecode & Opcodes (`vaster_instruction`)**: Must NOT know about AST frontend nodes, compiler implementation classes, host OS process handles, or host language object instances.
3. **LLM Models (`vaster_model`)**: Must NOT know about session history, context managers, tool dispatching loops, or opcode execution. Models are stateless inference processors.
4. **Sessions (`vaster_session`, `vaster_session_manager`)**: Must NOT know about tool call execution policies, maximum tool loop limits (`maxToolCallLoops`), or agent supervisor trees. Sessions are purely conversational memory and context heaps.
5. **Tools & Sandboxes (`vaster_tool`, `vaster_sandbox`)**: Must NOT know about LLM models, session conversation history, or ISA program execution state. Tools only map JSON inputs to JSON outputs.
6. **Agents & Supervisors (`vaster_agent`, `vaster_agent_manager_*`)**: Must NOT know about low-level ISA instruction decoding or program counter manipulation. Agents operate on model sessions, tasks, and tool managers.
7. **Security Policies (`vaster_policy`, `vaster_policy_engine`)**: Must NOT know about prompt text contents, model providers, or AST nodes. Policies strictly evaluate abstract actions against resource patterns.
8. **Continuations (`vaster_continuation`)**: Must NOT know about live socket handles, active model instances, host OS memory addresses, AST nodes (`vaster_ast`), domain specs (`vaster_domain`), or compiler classes (`vaster_compiler`). Continuations are pure serializable JSON snapshots of runtime execution state.
9. **Context Managers (`vaster_context`, `vaster_context_manager`)**: Must NOT know about tool execution, filesystem IO transactions, or agent supervisor trees. Context managers only shape token budgets and system instructions.
10. **Event Telemetry (`vaster_events`)**: Must NOT know how to mutate VM execution state, modify registers, or interrupt opcode dispatch. Telemetry is strictly passive and broadcast-only.

## 7. Dependency Addition Approval
- **Explicit User Approval Required**: ALWAYS ask for explicit user approval before adding any new dependency (production or dev_dependency) to any `pubspec.yaml` file across the workspace.
