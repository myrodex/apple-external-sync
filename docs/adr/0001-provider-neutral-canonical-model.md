# ADR 0001: Keep the canonical model provider-neutral

- **Status:** Accepted
- **Date:** 2026-10-10

## Context

The first integration is Apple Reminders, but users need synchronization with other providers and must be able to add a provider without changing every app and store. Provider APIs also disagree on identifiers, revisions, deletion semantics, ordering, recurrence, and field support.

## Decision

The sync engine owns provider-neutral list/task values, explicit external identity mappings, opaque cursors/revisions, tombstones, and conflict records. Each provider adapter translates at the boundary. Capability negotiation describes native, transformed, and unsupported fields. Unknown or unsupported data is rejected or surfaced as an explicit warning; it is not silently coerced.

## Consequences

- Domain and engine tests do not require a provider account.
- Provider-specific behavior is localized to adapters and capability metadata.
- Adding a provider requires a translation and capability profile rather than canonical-model forks.
- Some provider features cannot be represented exactly and must be rejected or reported as field loss.
- Canonical IDs must never be confused with provider IDs.
