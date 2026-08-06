# Changelog

## Unreleased

- Initial package: `ContextMmu` + `MmuStats` moved verbatim from
  `vaster_kv`. The bridge between virtual context regions and physical
  KV-cache state — deliberately the only component aware of both sides
  (rules.md Rule 6.15), and the landing zone for cache-aware context
  planning (roadmap goal C: token-exact prefix validation).
