# ADR 0002: Keep the optional relay stateless until a persistence contract exists

- **Status:** Accepted
- **Date:** 2026-10-10

## Context

A deployed HTTP endpoint is useful for health checks, protocol discovery, and future account-scoped forwarding. The repository does not yet define the deployment's database, token vault, provider-account lifecycle, or job delivery guarantees. A relay that invents an in-memory store would lose state on restart and could falsely claim sync success.

## Decision

The Vapor relay scaffold owns only process configuration, health/readiness, request correlation, and structured `not_configured` responses. It has no database dependency, provider credentials, sync state, or data-serving fallback. Data routes remain explicit extension points until a backend implementing `LocalStore` and account authorization is injected.

## Consequences

- The scaffold can be built and deployed without committing to a database or hosting provider.
- `/health` can report process liveness; `/ready` reports whether a backend has been configured.
- Protocol routes return a deterministic structured error while unconfigured, rather than persisting requests in memory.
- A future backend must be added behind protocols and tested for account isolation, idempotency, cursor durability, and tombstone retention before data routes are enabled.
