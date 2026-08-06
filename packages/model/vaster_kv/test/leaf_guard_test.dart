import 'dart:io';

import 'package:test/test.dart';

/// Rule 6.15's standing guard: `vaster_kv` is the KV *contracts* leaf.
/// Model/backend packages depend on it, so nothing context-shaped may
/// enter — the `ContextMmu` bridge lives in `vaster_context_mmu`, the
/// only component allowed to know both sides. If this fails, a
/// dependency was added that would leak the context layer transitively
/// into every KV backend.
void main() {
  // Packages live at packages/<group>/<name> — resolve by scanning the
  // group directories (the tree is the map; the guard follows it).
  File? pubspecOf(String package) {
    for (final group in Directory('../..').listSync().whereType<Directory>()) {
      final file = File('${group.path}/$package/pubspec.yaml');
      if (file.existsSync()) return file;
    }
    return null;
  }

  Set<String> directDeps(String package) {
    final file = pubspecOf(package);
    if (file == null) return const {};
    final production =
        file.readAsStringSync().split(RegExp(r'^dev_dependencies:', multiLine: true))[0];
    return RegExp(r'^\s{2}(vaster_\w+):', multiLine: true)
        .allMatches(production)
        .map((m) => m.group(1)!)
        .toSet();
  }

  Set<String> closure(String package) {
    final seen = <String>{};
    final todo = <String>{package};
    while (todo.isNotEmpty) {
      final current = todo.first;
      todo.remove(current);
      for (final dep in directDeps(current)) {
        if (seen.add(dep)) todo.add(dep);
      }
    }
    return seen;
  }

  test('direct deps: token estimation only', () {
    expect(directDeps('vaster_kv'), {'vaster_token_estimate'},
        reason: 'vaster_kv may depend on token estimation (Rule 6.12: '
            'estimates are centralized) and nothing else directly');
  });

  test('transitive closure never reaches the context layer', () {
    final reached = closure('vaster_kv');
    expect(reached.where((d) => d.contains('context')), isEmpty,
        reason: 'the contracts leaf must not drag vaster_context* into '
            'backend packages (Rule 6.15) — the ContextMmu bridge in '
            'vaster_context_mmu is the only component knowing both sides');
  });
}
