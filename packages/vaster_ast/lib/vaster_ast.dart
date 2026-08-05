/// Vaster's declarative AST — the Flutter-style surface.
///
/// This import contains no imperative nodes: everything here declares what a
/// pipeline *is* (scopes, values, branches, phases), never machine steps.
/// Two opt-in companions exist for lower altitudes:
///
///  * `package:vaster_ast/primitives.dart` — the low-level escape hatch
///    (heap verbs, raw loops, subroutines). Prefer the declarative
///    equivalents: `Knowledge`/`ContextBudget` over `AddContext`/
///    `EvictContext`, `AskHuman`/`ApprovalGate` over `YieldHuman`,
///    `RefineLoop`/`DecideLoop`/`Produce` over `While`, `Resilient` over
///    `TryCatch`.
///  * `package:vaster_ast/lowering.dart` — compiler lowering targets;
///    application code never needs it.
library;

export 'src/ast_lib.dart'
    hide
        AddContext,
        EvictContext,
        CompressContext,
        YieldHuman,
        While,
        Repeat,
        TryCatch,
        DefineSubroutine,
        CallSubroutine,
        PipelineBody,
        AgentProvisionHeader,
        ToolSetHeader,
        MountHeader,
        BudgetHeader,
        SandboxHeader,
        SelectModelHeader,
        InputsHeader,
        TaskExecution,
        ExecuteExecution,
        SendMessageExecution,
        ReceiveMessageExecution;

export 'package:vaster_context/vaster_context.dart'
    show
        ContextPriority,
        ContextLifetime,
        ContextCompressibility,
        ContextClass,
        ContextClassTable,
        BudgetShare,
        EvictionPolicy;
export 'package:vaster_model/vaster_model.dart' show RetryPolicy;
