# Architecture

This repository is a Swift Package Manager monorepo for a provider-neutral reminders synchronization protocol. The protocol is deliberately independent from any one provider: Apple Reminders is the first adapter, while Google Tasks, Microsoft Graph, and generic REST providers can be added without changing the canonical model.

## Repository map

The root `Package.swift` is the source of truth for the library targets and products. The Xcode project under `Apps/AppleExternalSyncApp` consumes the local `ExternalSync` and `SyncAppSupport` products; it is not a second Swift package and there are no `Apps/iOS` or `Apps/macOS` directories.

| Path | Swift target/product | Responsibility | Persistence/network boundary |
| --- | --- | --- | --- |
| `Sources/SyncDomain` | `SyncDomain` | Provider-neutral canonical list/task values, ownership, clocks, tombstones, conflicts, and merge primitives. | Pure Swift domain values and algorithms. |
| `Sources/SyncContracts` | `SyncContracts` | Adapter-facing remote resource, mutation, capability, authentication, and error contracts. | Pure Swift serialization and boundary contracts; depends on `SyncDomain`. |
| `Sources/SyncAdapters` | `SyncAdapters` | EventKit, Google Tasks, Microsoft Graph, and declarative generic REST adapters, OAuth support, and HTTP transport. | Provider/network boundary; credentials are supplied by the app's secure token store. |
| `Sources/SyncStore` | `SyncStore` | `SyncStateStore`, transactional `LocalStore` APIs, SQLite production persistence, and in-memory test doubles. | SQLite is the production checkpoint and audit boundary; the target links `sqlite3`. |
| `Sources/SyncEngine` | `SyncEngine` | Account-scoped pull/push orchestration, three-way merge, cursor advancement, and conflict creation. | Depends on domain, contracts, and store protocols; owns sequencing, not storage. |
| `Sources/SyncAppSupport` | `SyncAppSupport` | Runtime composition and Apple lifecycle integration used by device applications. | Wires injected adapters to `SyncEngine` and `SQLiteLocalStore`; no provider login singleton. |
| `Sources/ExternalSync` (`AppShell/`) | `ExternalSync` | SwiftUI app shell, provider connection factories, production coordinator, settings, and view-model state. | UI orchestration only; it composes the shared runtime and app-owned platform services. |
| `Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj` | Xcode targets `AppleExternalSync iOS` and `AppleExternalSync macOS`; schemes `AppleExternalSync-iOS` and `AppleExternalSync-macOS` | Runnable application packaging, Info.plists, URL scheme, EventKit permissions, background scheduling, login-item configuration, and platform entitlements. | User-device boundary. The project links the local `ExternalSync` and `SyncAppSupport` products. |
| `Relay` | Separate `SyncRelay` executable package | Optional stateless Vapor transport shell with liveness, readiness, request correlation, and not-configured responses. | No database, token store, provider credentials, or sync implementation. |
| `schemas` | — | Draft 2020-12 JSON Schemas for payload validation. | Canonical machine-readable contract. |
| `openapi` | — | OpenAPI 3.1 transport description and route-level references to schemas. | Edit `openapi/reminders-sync.yaml`; bundled output is generated. |
| `docs` | — | Normative protocol, architecture, ADRs, glossary, privacy, and operational guidance. | Human-readable contract and decisions. |
| `examples` | — | Synthetic request/response fixtures used by contract checks and docs. | Non-production data only. |
| `Tests` | Swift and Python test targets | Unit, integration, adapter, store, lifecycle, relay, and protocol-contract tests. | Failure paths, retries, conflicts, retention, and account isolation are first-class test cases. |

The root library target dependency graph is intentionally acyclic:

```text
SyncDomain
├── SyncContracts
├── SyncAdapters ──┐
├── SyncStore      ├── SyncEngine
└──────────────────┘       │
                           SyncAppSupport
                               │
                           ExternalSync (app shell)
```

More precisely, `SyncContracts` depends on `SyncDomain`; `SyncAdapters` depends on `SyncDomain` and `SyncContracts`; `SyncStore` depends on `SyncDomain`; `SyncEngine` depends on `SyncDomain`, `SyncContracts`, and `SyncStore`; `SyncAppSupport` depends on the adapter, contract, domain, engine, and store targets; and `ExternalSync` depends on `SyncAppSupport`. The separate `Relay/Package.swift` has its own `SyncRelay` and `SyncRelayTests` targets and does not add Vapor to the root package graph.
The root package test targets are `SyncDomainTests`, `SyncAdaptersTests`, `SyncStoreTests`, `SyncEngineTests`, and `ExternalSyncTests`; protocol regression tests live in `Tests/test_protocol.py`.

## Runtime data flow

1. The Apple application constructs `ProductionSyncCoordinator`. It uses a device-local SQLite database at `Application Support/AppleExternalSync/sync.sqlite` by default (inside the app sandbox on iOS), while provider tokens and pending OAuth state remain in Keychain.
2. A platform/provider adapter reads remote changes and normalizes them into `RemoteChange` values. EventKit selection is an app policy: a complete EventKit snapshot can represent deletions, while an explicit selected-list scope deliberately defers changes outside that scope.
3. `SyncEngine` loads the checkpoint with `load(account:)` for exactly one authenticated provider account. The production `SQLiteLocalStore` stores one canonical checkpoint row per `(provider, account_id)` and account-scoped `sync_runs`; it never uses a shared mutable production checkpoint.
4. The engine applies changes using explicit identity mappings and a field-level three-way merge. Concurrent edits produce durable conflicts; wall-clock ordering is never a conflict resolver.
5. The engine writes the new state and cursor as one atomic update to that account's SQLite row. Cursor advancement happens only after every change in the page is durable; rejected pushes leave the previous cursor so the page is replayed safely. A durable run record is written before provider I/O and finalized after the checkpoint, so a relaunch can surface an interrupted run as a failure.
6. Outbound mutations use conditional writes and idempotency where the provider supports them. Provider field loss is surfaced as a capability/warning decision, never silently discarded.
7. The optional relay can expose protocol-shaped routes only after a deployment supplies an account-authorized backend. With no backend it returns a structured `not_configured` response rather than inventing in-memory persistence.

## Account checkpoint and legacy migration

Current SQLite state is partitioned by provider account in `sync_account_state(provider, account_id, payload)`. Sync-run history is likewise partitioned by provider and account. Opening `SQLiteLocalStore` runs schema migrations and then performs a one-time migration of the old singleton `sync_state(id = 1)` row inside an immediate SQLite transaction:

- Ownership evidence comes from explicit owner maps, provider mappings/replicas, conflicts, and cursors. Records with no ownership evidence can be assigned only when exactly one account is known.
- Records whose ownership is missing, ambiguous, or contradictory are written to `sync_state_quarantine` with a migration reason. Their payload is not returned by `load(account:)`; `isQuarantined` keeps those canonical IDs reserved so a later account cannot claim them accidentally. Repair is an explicit migration/maintenance operation, not a best-effort guess.
- Existing account rows are merged with safely migrated records, then the legacy singleton row is deleted only after the transaction commits. A crash before commit leaves the legacy row available for retry.
- Disconnect deletes only the selected account's checkpoint and run history. Provider credential revocation/removal is a separate Keychain operation owned by the app connection factory. Quarantined records remain reserved until an explicit repair.

The engine-facing methods are always account-scoped. The aggregate `load()`/`save()` methods remain for store compatibility and migration tooling; production runtime composition uses `load(account:)` and `save(_:account:)`.

`LocalStore` is a lower-level compatibility/query API, not the engine authorization boundary. Its historical mapping, snapshot, provider-cursor, tombstone, and conflict tables predate account-partitioned checkpoints and do not carry the canonical `(provider, accountID)` key. The production coordinator and `SyncEngine` do not use those tables for account state; callers must not use provider-only `LocalStore` queries to serve or authorize cross-account data. New account-aware persistence belongs in `SyncStateStore` and its `sync_account_state` rows.

## Invariants

- Canonical IDs and provider IDs are distinct. Provider identifiers and cursors are opaque and are never parsed for ordering or authorization.
- Every resource operation is account-scoped. A valid-looking ID from another account must not reveal whether it exists; canonical records without provider mappings carry explicit ownership so they cannot be claimed by a second account.
- Durable run history is account-scoped and bounded by retention. Disconnect removes the selected account's mappings, canonical state, cursors, conflicts, ownership, and run history without removing another account's data.
- Deletes are soft deletes with tombstones retained for at least 30 days. Replay of an old upsert must not resurrect a deleted resource.
- Updates/deletes require an expected revision or ETag. Conflicts are explicit and actionable; last-write-wins is not an acceptable fallback.
- Idempotency keys bind a retry to the exact request body. Reusing a key for different bytes is a conflict.
- Credentials and provider tokens are device/Keychain concerns. They do not enter canonical JSON, query strings, logs, examples, or the stateless relay.
- Configured provider base URLs must be HTTPS origins without embedded credentials. Declarative REST endpoint paths are relative and reject query/fragment injection, traversal, host-relative URLs, and control characters. Provider-supplied pagination or delta links are accepted only when HTTPS and same-origin (same scheme, host, and effective port); unsafe links are rejected before a bearer token is sent.
- Notes, titles, URLs, warning text, and provider metadata are untrusted data. Renderers must escape them and never interpret them as instructions.

## Testing strategy

- Unit-test pure identity, merge, cursor, tombstone, and capability behavior with deterministic clocks.
- Exercise stores with both the in-memory implementation and SQLite implementation, including rollback, account-scoped disconnect, legacy checkpoint migration, quarantine reservation, durable run recovery, and retention cleanup.
- Use adapter transport fakes to test auth failures, unsafe base URLs, cross-origin continuation links, malformed responses, rate limits, conditional-write failures, and retry safety.
- Validate every JSON Schema and lint the OpenAPI document in CI. Contract fixtures should include field-loss warnings, conflicts, cursor expiry, and idempotency mismatch.
- Keep relay tests stateless: health/readiness and structured not-configured responses are testable without a database or provider account.

## Apple platform lifecycle

`EventKitRemindersAdapter` emits a complete provider snapshot only when its selection policy is `AllEventKitListsSelection`. Explicit or mutable list selection is a partial snapshot, so omitted lists are not interpreted as remote deletions. `SelectedListsSyncAdapter` also preserves global provider cursors when a pull contains deferred, unselected changes.

On iOS, `AppleSyncLifecycle` owns `BGTaskScheduler` registration/rescheduling policy and propagates the actual sync result to the task completion callback. Background and foreground failures are recorded through the production coordinator, and the next coordinator initialization restores the latest account-scoped audit result instead of silently clearing the error. On macOS, the app uses `SMAppService.mainApp` by default: login-item behavior is intentionally visible and status/approval/System Settings controls are exposed by the app shell. An optional `ExternalSyncLoginItemBundleIdentifier` changes the target to a separately packaged helper under `Contents/Library/LoginItems`.

## Build and deployment boundaries

The checked-in Xcode project defaults both project configurations to `CODE_SIGNING_ALLOWED = NO` and `CODE_SIGNING_REQUIRED = NO`; the documented `xcodebuild` commands therefore provide an unsigned compile check. They do not produce an installable device build or distributable archive and cannot validate provisioning, code-signature entitlements, Keychain behavior, EventKit authorization, background scheduling, login-item registration, or OAuth callback delivery. Those paths require a normally signed Xcode build with a development team and the appropriate simulator/device or macOS runtime.

No production deployment manifest, container image, database migration service, credential vault, or hosting-provider configuration is checked in. The optional relay can be launched as a Vapor process, but a deployment must provide TLS termination, process/port supervision, health checks, durable account authorization and persistence, provider credential handling, retention/purge policy, and observability before enabling data routes. The current relay scaffold is intentionally not ready to serve sync data.
