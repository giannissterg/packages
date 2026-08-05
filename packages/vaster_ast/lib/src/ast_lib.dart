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
import 'package:vaster_model/vaster_model.dart';

part 'binding.dart';
part 'build_context.dart';
part 'vaster_node.dart';
part 'composable_node.dart';
part 'nodes.dart';
part 'coordination.dart';
part 'sdd.dart';
