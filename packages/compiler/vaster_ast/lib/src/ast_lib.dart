/// The single Dart library holding every AST node (VasterNode is sealed, so
/// all subclasses live here). Consumers never import this file directly —
/// they import one of the three export shells:
///
///  * `package:vaster_ast/vaster_ast.dart`  — the declarative surface
///  * `package:vaster_ast/primitives.dart`  — low-level escape hatch
///  * `package:vaster_ast/lowering.dart`    — compiler lowering targets
library;

import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_domain/vaster_domain.dart';
// The AST stays ISA-free — this narrow import is the one ABI naming
// convention the declarative tier must agree on with the runtime (the
// approval-flag register an ApprovalGate's When reads).
import 'package:vaster_instruction/vaster_instruction.dart'
    show hitlStatusRegister;
import 'package:vaster_model/vaster_model.dart';

part 'binding.dart';
part 'build_context.dart';
part 'vaster_node.dart';
part 'composable_node.dart';
part 'nodes_declarative.dart';
part 'nodes_context.dart';
part 'nodes_control_flow.dart';
part 'nodes_lowering.dart';
part 'coordination.dart';
part 'sdd.dart';
