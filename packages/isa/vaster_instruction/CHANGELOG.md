## Unreleased

- `SelectModelOp` carries an ordered `fallbacks` descriptor list (REL-P3).
  Additive and wire-compatible: the JSON key is emitted only when a chain
  is declared, so pre-chain programs (and VBC payloads) stay byte-identical.

## 0.3.0

- New `register_conventions.dart`: `hitlStatusRegister` / `hitlStatusSuffix`
  and `decideRationaleRegister` / `decideRationaleSuffix` — the ABI
  sibling-register names shared by the runtime, AST, and analyzer.

## 0.2.0

- Initial version.
