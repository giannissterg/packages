import 'dart:io';

import 'package:vaster_cli/vaster_cli.dart';

void main(List<String> args) async {
  final runner = VasterCliRunner();
  final exitCode = await runner.run(args);
  exit(exitCode);
}
