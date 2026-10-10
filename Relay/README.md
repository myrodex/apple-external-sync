# SyncRelay

`SyncRelay` is an optional stateless Vapor HTTP shell in its own SwiftPM package (`Relay/Package.swift`). It provides process liveness, readiness, request correlation, and a deterministic `not_configured` response for protocol discovery until a deployment supplies a real account-authorized backend.

It intentionally does **not** provide:

- a database or in-memory sync state;
- provider credentials, token exchange, or account linking;
- cursor, idempotency, tombstone, or mutation persistence;
- a fake capability response that could mislead clients;
- a production deployment manifest, container image, hosting-provider configuration, or TLS termination.

## Run locally

```sh
swift test --package-path Relay --parallel
swift run --package-path Relay
```

The process uses Vapor's environment-configured port. `GET /healthz` returns liveness and echoes a bounded `X-Request-Id`. `GET /readyz` and `GET /v1/capabilities` return `503` with `code: not_configured`; the scaffold cannot claim readiness or provider capabilities until an actual backend is implemented. The current repository does not deploy or call this relay from the Apple app targets—the device app uses injected provider adapters and local SQLite state directly.

## Deployment assumptions

A deployment may run the executable behind its own process supervisor and TLS reverse proxy, but must provide all of the following before exposing sync data:

1. HTTPS/TLS termination and a secure forwarding policy for `X-Request-Id`.
2. Authentication and account authorization for every request.
3. A durable backend for account checkpoints, cursor advancement, idempotency responses, tombstones, conflicts, and mutation outcomes.
4. Provider credential storage, token exchange/revocation, and account-linking lifecycle outside this stateless shell.
5. Retention/purge policy, backups, migrations, rate limiting, structured logs, metrics, and readiness checks appropriate to the chosen host.

There is no production deployment recipe in this repository. Treat `/healthz` as a process-liveness check only; a successful health response does not mean the service can serve sync traffic. `/readyz` should remain failing until the deployment supplies and verifies the backend.

## Add a backend

Implement a separate account-authorized backend behind an explicit configuration/protocol boundary, and change the hard-coded readiness/capability handlers only after that backend owns authentication, authorization, durable cursor/idempotency state, tombstone retention, provider credentials, and protocol responses. No backend configuration type exists in this scaffold today. Keep the relay as transport/composition code; do not add persistence to this target as a shortcut. Add integration tests for account isolation, retries, cursor durability, tombstone retention, and failure/restart recovery before changing readiness behavior.
