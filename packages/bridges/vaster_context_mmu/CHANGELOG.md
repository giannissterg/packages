# Changelog

## 0.5.0

- `contentRenderer` — the alignment-contract hook: backends whose prompt
  composition renders regions inject their renderer so materialized
  state is a token-exact prefix of the prompts it will be validated
  against; the default stays the canonical fingerprint-derivation form,
  and the page-table key is always the canonical fingerprint (provenance
  addressing — the renderer shapes the payload, never the key).
- `MmuStats.tokensMaterialized` — fault-side prefill cost, for host
  reporting.

- Initial package: `ContextMmu` + `MmuStats` moved verbatim from
  `vaster_kv`. The bridge between virtual context regions and physical
  KV-cache state — deliberately the only component aware of both sides
  (rules.md Rule 6.15), and the landing zone for cache-aware context
  planning (roadmap goal C: token-exact prefix validation).
