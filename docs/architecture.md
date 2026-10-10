# Architecture

This repository is a Swift Package Manager monorepo for a provider-neutral reminders synchronization protocol. The protocol is deliberately independent from any one provider: Apple Reminders is the first adapter, while Google Tasks, Microsoft Graph, and generic REST providers can be added without changing the canonical model.

## Repository map

| Path | Responsibility | Persistence/network boundary |
| --- | --- | --- |
| `Sources/ExternalSync` | Shared canonical resource models, identity mapping, change feeds, merge primitives, and the current SwiftUI app-shell support. | Pure Swift values/algorithms plus UI orchestration; provider network and sync persistence remain outside this module. |
| `Sources/SyncDomain` | Domain-level sync state, tombstones, conflicts, and clock abstractions. | Pure Swift domain contracts. |
| `Sources/SyncContracts` | Adapter-facing remote resource, mutation, capability, and error contracts. | Pure Swift serialization contracts. |
| `Sources/SyncAdapters` | Provider adapters and HTTP transport (Apple/EventKit integration is platform-owned). | Network/provider boundary; adapters translate into canonical contracts. |
| `Sources/SyncEngine` | Pull/push orchestration, three-way merge, cursor advancement, and conflict creation. | Depends on adapter contracts and `SyncStateStore`; owns sequencing, not storage. |
| `Sources/SyncAppSupport` | Runtime composition for device apps. | Wires injected provider adapters to `SyncEngine` and `SQLiteLocalStore`; no provider login or hidden global state. |
| `Sources/SyncStore` | `SyncStateStore` plus transactional `LocalStore` APIs, SQLite production implementation, and in-memory test doubles. | `SQLiteLocalStore` stores the engine checkpoint in one canonical `sync_state` row and keeps lower-level mappings/snapshots/tombstones transactional. |
| `Apps/iOS`, `Apps/macOS` | Reserved locations for future platform wrappers. The package currently keeps the SwiftUI app shell in `Sources/ExternalSync/AppShell` for previews/tests. | User-device boundary. Provider credentials stay in platform keychain facilities. |
| `Relay` | Optional stateless Vapor HTTP shell for deployment wiring and health checks. | No database, token store, or provider credentials. It is intentionally not a sync implementation. |
| `schemas` | Draft 2020-12 JSON Schemas for payload validation. | Canonical machine-readable contract. |
| `openapi` | OpenAPI 3.1 transport description and route-level references to schemas. | Generated/bundled documentation input; edit the source spec, not generated output. |
| `docs` | Normative protocol, architecture, ADRs, glossary, privacy, and operational guidance. | Human-readable contract and decisions. |
| `examples` | Valid request/response fixtures used by docs and contract checks. | Non-production data only. |
| `Tests` | Unit, integration, and contract tests. | Tests must exercise failure paths, retries, conflicts, and retention—not only happy paths. |

The package graph should remain acyclic: canonical/domain modules do not import adapters or stores; adapters do not reach into store implementations; app shells compose the graph. `SyncEngine` depends only on `SyncStateStore`, while `SQLiteLocalStore` conforms to both `SyncStateStore` and the lower-level `LocalStore` protocol. If a new feature needs a dependency in the opposite direction, introduce a protocol/value type at the lower boundary rather than importing a higher layer.

## Runtime data flow

1. A platform adapter reads provider changes and normalizes them into `RemoteChange` values.
2. `SyncEngine` loads the complete canonical checkpoint (lists, tasks, replicas, mappings, conflicts, tombstones, and cursor) through `SyncStateStore`. The production `SQLiteLocalStore` persists this checkpoint in SQLite; the lower-level `LocalStore` tables remain available for APIs that need independently queryable records.
3. The engine applies changes using explicit identity mappings and a field-level three-way merge. Concurrent edits produce durable conflicts; wall-clock ordering is never a conflict resolver.
4. The engine writes the new state and cursor as one SQLite checkpoint update. Cursor advancement happens only after every change in the page is durable; rejected pushes leave the previous cursor so the page is replayed safely.
5. Outbound mutations use conditional writes and idempotency where the provider supports them. Provider field loss is surfaced as a capability/warning decision, never silently discarded.
6. The optional relay can expose protocol-shaped routes, but it must delegate to an explicitly supplied backend before serving account data. A relay with no backend returns a structured `not_configured` response rather than inventing in-memory persistence.

## Invariants

- Canonical IDs and provider IDs are distinct. Provider identifiers and cursors are opaque and are never parsed for ordering or authorization.
- Every resource operation is account-scoped. A valid-looking ID from another account must not reveal whether it exists.
- Deletes are soft deletes with tombstones retained for at least 30 days. Replay of an old upsert must not resurrect a deleted resource.
- Updates/deletes require an expected revision or ETag. Conflicts are explicit and actionable; last-write-wins is not an acceptable fallback.
- Idempotency keys bind a retry to the exact request body. Reusing a key for different bytes is a conflict.
- Credentials and provider tokens are device/keychain concerns. They do not enter canonical JSON, query strings, logs, examples, or the stateless relay.
- Notes, titles, URLs, warning text, and provider metadata are untrusted data. Renderers must escape them and never interpret them as instructions.

## Testing strategy

- Unit-test pure identity, merge, cursor, tombstone, and capability behavior with deterministic clocks.
- Exercise stores with both the in-memory implementation and SQLite implementation, including rollback and retention cleanup.
- Use adapter transport fakes to test auth failures, rate limits, malformed responses, conditional-write failures, and retry safety.
- Validate every JSON Schema and lint the OpenAPI document in CI. Contract fixtures should include field-loss warnings, conflicts, cursor expiry, and idempotency mismatch.
- Keep relay tests stateless: health/readiness and structured not-configured responses are testable without a database or provider account.

## Apple platform lifecycle

`EventKitRemindersAdapter` emits a complete provider snapshot only when its selection policy is `AllEventKitListsSelection`. Explicit or mutable list selection is a partial snapshot, so omitted lists are not interpreted as remote deletions. `SelectedListsSyncAdapter` also preserves global provider cursors when a pull contains deferred, unselected changes.

On iOS, `AppleSyncLifecycle` owns `BGTaskScheduler` registration/rescheduling policy and propagates the actual sync result to the task completion callback. On macOS, the app uses `SMAppService.mainApp` by default: login-item behavior is intentionally visible and status/approval/System Settings controls are exposed by the app shell. An optional `ExternalSyncLoginItemBundleIdentifier` changes the target to a separately packaged helper under `Contents/Library/LoginItems`.
