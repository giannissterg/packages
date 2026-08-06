# Changelog

## Unreleased

- **BREAKING**: the codec/value split — `KvStateImage` is now the parsed VALUE (zero-copy accessors, `prefixDivergence`); parsing, layout, and initialization live in `KvStateImageCodec`, a const-constructible external class (a v2 format arrives as another codec, not a static rewrite). `engineTagOf` stays static: it is a pure derivation convention.

- **`KvStateImage` — the KV State Image codec (spec v1).** KV frames'
  payloads become a specified, versioned, language-agnostic binary
  format (`docs/specs/KV_STATE_IMAGE.md`): engine state plus the
  provenance needed to reuse it safely — the exact decoded token ids,
  an opaque `engineTag` (producer identity: build + model), and the
  source-content fingerprint. Container-agnostic — lives here with the contracts, not with any transport (Rule 10 placement law). Zero-copy by construction: parsing
  validates header/bounds/padding, then every accessor is a typed view
  (`Int32List` token ids, `Uint8List` state, `stateOffset` for the
  pointer path where engines read/write state in mapped pages).
  `prefixDivergence` implements the spec's normative token-exact reuse
  check with a diagnosable divergence index. Conformance is anchored by
  a committed golden-bytes fixture an implementation in any language
  must reproduce.


- **BREAKING**: `ContextMmu` and `MmuStats` moved to the new
  `vaster_context_mmu` package. `vaster_kv` is now the KV *contracts*
  leaf (handle, controller, capabilities, in-memory simulator) — its
  transitive closure no longer reaches the context layer, so backend
  packages depending on the contracts stop transitively knowing context
  managers (rules.md Rule 6.15). Leaf-ness is enforced by
  `test/leaf_guard_test.dart` (direct deps + closure walk).
