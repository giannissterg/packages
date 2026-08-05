# Changelog

## 0.3.0

- `AgentDescriptor.sessionIdFor`: the shared `sess_<agentId>` session-naming
  convention (previously hand-rolled by three producers).

## 0.2.0

- Initial version: `AgentDescriptor` extracted from `vaster_agent` so the
  ISA (`CreateAgentOp`) no longer drags the live agent interface — and its
  session/context closure — into `vaster_instruction`.
