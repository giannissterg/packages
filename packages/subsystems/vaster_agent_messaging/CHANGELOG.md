# Changelog

## Unreleased

- Rule 11 V4: `importInboxes` returns the number of messages hydrated.

## 0.4.0

- `BasicAgentMessagingHub.exportInboxes`/`importInboxes` — undelivered actor
  messages are durable state (a message sent before suspension must pop
  after resume).

## 0.3.0

- Actor messaging hub: send, inbox, pop, streams.
