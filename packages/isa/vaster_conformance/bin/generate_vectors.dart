import 'dart:io';

import 'package:vaster_conformance/vaster_conformance.dart';

/// Regenerates every golden conformance vector.
///
///     dart run vaster_conformance:generate_vectors [outDir]
void main(List<String> args) async {
  final outDir = Directory(args.isNotEmpty ? args.first : 'vectors');
  outDir.createSync(recursive: true);

  var failures = 0;
  for (final spec in vectorSpecs) {
    try {
      final generated = await generateVector(spec, outDir);
      stdout.writeln('generated ${spec.name} (${generated.envelopeBytes} bytes envelope)');
    } catch (e) {
      failures++;
      stderr.writeln('FAILED ${spec.name}: $e');
    }
  }
  if (failures > 0) {
    stderr.writeln('$failures vector(s) failed to generate.');
    exitCode = 1;
  }
}
