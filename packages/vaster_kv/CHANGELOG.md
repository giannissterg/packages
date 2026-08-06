# Changelog

## Unreleased

- **BREAKING**: `ContextMmu` and `MmuStats` moved to the new
  `vaster_context_mmu` package. `vaster_kv` is now the KV *contracts*
  leaf (handle, controller, capabilities, in-memory simulator) — its
  transitive closure no longer reaches the context layer, so backend
  packages depending on the contracts stop transitively knowing context
  managers (rules.md Rule 6.15). Leaf-ness is enforced by
  `test/leaf_guard_test.dart` (direct deps + closure walk).
