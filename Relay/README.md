# SyncRelay

`SyncRelay` is an optional stateless Vapor HTTP shell. It provides process liveness, readiness, request correlation, and a deterministic `not_configured` response for protocol discovery until a deployment supplies a real account-authorized backend.

It intentionally does **not** provide:

- a database or in-memory sync state;
- provider credentials, token exchange, or account linking;
- cursor, idempotency, tombstone, or mutation persistence;
- a fake capability response that could mislead clients.

## Run locally

```sh
swift run --package-path Relay
```

The default Vapor port is used by the process environment. `GET /healthz` returns liveness. `GET /readyz` and `GET /v1/capabilities` return `503` with `code: not_configured`; the scaffold cannot claim readiness until an actual backend is implemented.

## Add a backend

Implement a separate account-authorized backend and pass `RelayConfiguration(backendConfigured: true)` only after it owns authentication, authorization, durable cursor/idempotency state, tombstone retention, provider credentials, and protocol responses. Keep the relay as transport/composition code; do not add persistence to this target as a shortcut.
