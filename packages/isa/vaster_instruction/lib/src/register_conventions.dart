/// ABI register-naming conventions shared across the toolchain.
///
/// These sibling-register names are part of the ISA's ABI: the runtime writes
/// them, the AST lowering reads them, and the program analyzer models them.
/// They live here — in the one package every layer already imports — so no
/// producer or consumer hand-rolls the suffix string.
library;

/// Suffix of the boolean approval flag written alongside a HITL output
/// register when the human responds ([YieldHumanInteractionOp.request]).
const String hitlStatusSuffix = '_status';

/// The boolean approval-flag register for a HITL [outputVar]: `true` when the
/// response status is affirmative (approved/answered).
String hitlStatusRegister(String outputVar) => '$outputVar$hitlStatusSuffix';

/// Suffix of the rationale register written alongside a [DecideOp] output
/// register when the model explains its choice.
const String decideRationaleSuffix = '_rationale';

/// The rationale register for a [DecideOp] [outputVar].
String decideRationaleRegister(String outputVar) =>
    '$outputVar$decideRationaleSuffix';

/// Suffix of the task-outcome register written alongside a
/// [DispatchAgentTaskOp]/[DispatchParallelTasksOp] output register: the
/// sealed `TaskOutcome`'s stable KIND string (`completed`,
/// `model-failure`, `quota-exceeded`, `cancelled`, `refused`,
/// `failure`). The ISA carries the kind as a plain register string — it
/// never references the sealed type (Rule 1 handles-and-descriptors).
const String taskOutcomeSuffix = '_outcome';

/// The outcome-kind register for a dispatch [outputVar].
String taskOutcomeRegister(String outputVar) => '$outputVar$taskOutcomeSuffix';
