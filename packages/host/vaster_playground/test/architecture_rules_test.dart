import 'dart:io';

import 'package:test/test.dart';

/// Mechanical enforcement of rules.md Rule 1 — the compiler-frontend
/// isolation boundary.
///
/// The frontend packages (`vaster_ast`, `vaster_domain`, `vaster_compiler`)
/// must never be referenced by any runtime, ISA, VM, continuation, or backend
/// package: not imported, not exported, and not declared as a dependency
/// (production or dev). This test walks the real package sources so a
/// violation fails the suite instead of accumulating silently.
void main() {
  const frontendPackages = ['vaster_ast', 'vaster_domain', 'vaster_compiler'];

  /// The protected set, exactly as rules.md Rule 1 lists it. Prefixes ending
  /// in `_` match every package in that family (e.g. `vaster_model_*`).
  const protectedExact = [
    'vaster_instruction',
    'vaster_runtime',
    'vaster_vm',
    'vaster_continuation',
    'vaster_continuation_manager',
    'vaster_resources',
    'vaster_events',
    'vaster_policy',
    'vaster_policy_engine',
    'vaster_budget',
    'vaster_scheduler',
    'vaster_tool',
    'vaster_tool_manager',
  ];
  const protectedPrefixes = [
    'vaster_model_',
    'vaster_filesystem_',
    'vaster_sandbox_',
    'vaster_agent_',
    'vaster_session_',
    'vaster_context_',
  ];

  /// Locates the workspace `packages/` directory from wherever the test
  /// runs. The tree is grouped (packages/<group>/<name>) — the ISA's
  /// home anchors the search.
  Directory packagesDir() {
    var dir = Directory.current;
    while (true) {
      final candidate = Directory('${dir.path}/packages');
      if (candidate.existsSync() && Directory('${candidate.path}/isa/vaster_instruction').existsSync()) {
        return candidate;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) {
        fail(
          'Could not locate the workspace packages/ directory '
          'from ${Directory.current.path}',
        );
      }
      dir = parent;
    }
  }

  bool isProtected(String packageName) =>
      protectedExact.contains(packageName) || protectedPrefixes.any(packageName.startsWith);

  // Also protect exact family roots (vaster_session, vaster_context,
  // vaster_filesystem, vaster_sandbox, vaster_agent, vaster_model): rules.md
  // names the families; the bare interface packages are runtime-side too.
  const protectedFamilyRoots = [
    'vaster_model',
    'vaster_filesystem',
    'vaster_sandbox',
    'vaster_agent',
    'vaster_session',
    'vaster_context',
  ];

  // Two-level tree: packages/<group>/<name>.
  late final List<Directory> protectedDirs =
      packagesDir()
          .listSync()
          .whereType<Directory>()
          .expand((group) => group.listSync().whereType<Directory>())
          .where((d) {
            final name = d.path.split(Platform.pathSeparator).last;
            return isProtected(name) || protectedFamilyRoots.contains(name);
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('Rule 1: no runtime package references a frontend package in Dart code', () {
    final violations = <String>[];

    for (final pkg in protectedDirs) {
      final dartFiles = pkg
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final file in dartFiles) {
        final content = file.readAsStringSync();
        for (final frontend in frontendPackages) {
          if (content.contains('package:$frontend/')) {
            violations.add('${file.path} references package:$frontend/');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Runtime/ISA/backend packages must never import the compiler '
          'frontend (rules.md Rule 1):\n${violations.join('\n')}',
    );
  });

  test('Rule 1: no runtime package declares a frontend pubspec dependency', () {
    final violations = <String>[];

    for (final pkg in protectedDirs) {
      final pubspec = File('${pkg.path}/pubspec.yaml');
      if (!pubspec.existsSync()) continue;
      final content = pubspec.readAsStringSync();
      for (final frontend in frontendPackages) {
        // Matches a dependency key line, e.g. `  vaster_domain:`.
        if (RegExp('^\\s{2}$frontend:', multiLine: true).hasMatch(content)) {
          violations.add('${pubspec.path} declares $frontend');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Runtime/ISA/backend pubspecs must not depend on the compiler '
          'frontend, even as dev_dependencies (rules.md Rule 1):\n'
          '${violations.join('\n')}',
    );
  });

  test('protected package set actually matches the workspace', () {
    // Guard the guard: if the workspace grows a new runtime-family package,
    // the prefix rules should pick it up; this assertion documents the
    // currently protected set so unexpected shrinkage is visible in review.
    final names = protectedDirs.map((d) => d.path.split(Platform.pathSeparator).last).toList();
    expect(
      names,
      containsAll(['vaster_instruction', 'vaster_runtime', 'vaster_vm']),
      reason: 'core runtime packages must always be under the boundary guard',
    );
    expect(
      names.length,
      greaterThanOrEqualTo(25),
      reason:
          'the protected set unexpectedly shrank — was a runtime '
          'package renamed outside the known families?',
    );
  });
}
