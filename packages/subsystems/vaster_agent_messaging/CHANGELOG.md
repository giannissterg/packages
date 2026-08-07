# Changelog

## 0.5.0

- **BREAKING (C wave)**: `sendMessage` returns the message id — the
  same handle idiom `publish` uses; fan-out is not a sanctioned sink.

- **BREAKING (A3)**: `exportInboxes`/`importInboxes` join the
  `AgentMessagingHub` contract — undelivered messages survive a
  checkpoint for ANY hub implementation, not just the in-repo one.

- **BREAKING (Rule 11 V6)**: `clearInbox` returns the messages dropped;
  `close` returns whether this call closed the hub.

- Rule 11 V4: `importInboxes` returns the number of messages hydrated.

## 0.4.0

- `BasicAgentMessagingHub.exportInboxes`/`importInboxes` — undelivered actor
  messages are durable state (a message sent before suspension must pop
  after resume).

## 0.3.0

- Actor messaging hub: send, inbox, pop, streams.
