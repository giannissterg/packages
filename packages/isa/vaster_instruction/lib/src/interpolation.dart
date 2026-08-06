/// ISA-level register interpolation — normative spec.
///
/// The following instruction string fields are *interpolated fields*:
/// [PromptOp.promptText]; [DispatchAgentTaskOp.taskPrompt];
/// [ParallelTaskDispatch.taskPrompt]; [WriteFileOp.content] and
/// [WriteFileOp.vfsPath]; [ReadFileOp.vfsPath]; [ExecSandboxOp.code];
/// [AddContextOp.text]; [DecideOp.prompt];
/// [YieldHumanInteractionOp]'s request prompt; and the string leaf values of
/// [SendMessageOp.payload], recursively.
///
/// At execution time a conforming runtime MUST rewrite each interpolated
/// field as follows: `$$` becomes a literal `$`; `${name}` — where `name`
/// matches `[A-Za-z_][A-Za-z0-9_]*` — becomes the current value of register
/// `name` (string values verbatim, non-string values as canonical JSON, a
/// present-but-null register as the empty string). An unresolvable reference
/// is left verbatim and SHOULD be surfaced as a runtime warning. All other
/// text is literal.
///
/// Identity and handle fields (agent/session/region/sandbox ids, mount
/// prefixes), tool definitions, schemas, and `CheckPolicyOp.resource` are
/// never interpolated. Path fields interpolate *before* policy checks so
/// policy always evaluates the resolved path.
abstract final class RegisterInterpolation {
  /// Matches either an escape (`$$`) or a reference (`${name}`); group 1
  /// captures the register name of a reference (null for an escape).
  static final RegExp token = RegExp(r'\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

  /// The escape sequence producing a literal `$`.
  static const String escape = r'$$';

  /// Cheap pre-test: can [text] possibly contain interpolation tokens?
  static bool mentions(String text) => text.contains(r'$');
}
