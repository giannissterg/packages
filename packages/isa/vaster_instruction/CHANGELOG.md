## 0.5.0

- Effect-scope opcodes (REL-P4): `push_effect_scope` / `pop_effect_scope` /
  `mark_effect_retry` — the compiled brackets of a retry region's dedup
  window. Zero-payload, zero-cost; `Resilient` emits them.
- `SelectModelOp` carries an ordered `fallbacks` descriptor list (REL-P3).
  Additive and wire-compatible: the JSON key is emitted only when a chain
  is declared, so pre-chain programs (and VBC payloads) stay byte-identical.

## 0.3.0

- New `register_conventions.dart`: `hitlStatusRegister` / `hitlStatusSuffix`
  and `decideRationaleRegister` / `decideRationaleSuffix` — the ABI
  sibling-register names shared by the runtime, AST, and analyzer.

## 0.2.0

- Initial version.
