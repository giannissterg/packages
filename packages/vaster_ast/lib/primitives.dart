/// Low-level AST escape hatch — imperative primitives that the declarative
/// tier lowers onto. Reach for `package:vaster_ast/vaster_ast.dart` first:
/// every node here has a declarative superior for the common case.
library;

export 'src/ast_lib.dart'
    show
        AddContext,
        EvictContext,
        CompressContext,
        YieldHuman,
        While,
        Repeat,
        TryCatch,
        DefineSubroutine,
        CallSubroutine;
