## 0.1.0

- **D**: extracted from `vaster_model` — `CancellationToken` and
  `CancelledException` are a dependency leaf shared by models, tools,
  and sandboxes. The sandbox layer no longer depends on the whole model
  domain for one token type; `vaster_model` re-exports both names, so
  model-domain consumers are unaffected.
