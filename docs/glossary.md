# Glossary

- **Account checkpoint** — The complete canonical sync projection for exactly one `(provider, accountID)`, including lists, tasks, mappings, replicas, cursors, conflicts, ownership, and tombstone-bearing records. Production `SQLiteLocalStore` stores one checkpoint row per account.
- **Account scope** — The authenticated provider/sync account boundary. Every canonical resource, mapping, cursor, mutation, and conflict is authorized against exactly one account.
- **Canonical ID** — An ID assigned by the sync service to a provider-neutral list or task. It is not a provider's remote ID and is not a credential.
- **Checkpoint migration** — The one-time SQLite migration that partitions the legacy singleton `sync_state` row using explicit ownership evidence. Safely attributable records move to account checkpoints; missing or conflicting records move to quarantine rather than being guessed.
- **Cursor** — An opaque checkpoint for one account and one changes-feed filter. Clients persist only the server-returned next cursor.
- **ETag / revision** — Server/provider version metadata used for compare-and-swap writes. Clients treat both as opaque.
- **External identity** — The tuple identifying a provider object (`source`, entity type, and provider ID).
- **Field loss** — A provider cannot represent a submitted field exactly. The operation is rejected unless the caller explicitly accepts loss; accepted loss yields a warning.
- **Keychain** — Apple platform secure storage used for provider refresh/access tokens and short-lived OAuth state. It is separate from the canonical SQLite checkpoint and unavailable to portable non-Apple test runs.
- **LocalStore** — The lower-level compatibility/query API for mappings, provider cursors, snapshots, tombstones, conflict records, and sync-run audit data. Its historical tables are not the account authorization boundary; production engine state belongs to account-partitioned `SyncStateStore` checkpoints. `SQLiteLocalStore` implements both protocols in production; an in-memory implementation supports deterministic tests.
- **Mapping** — Durable association between an external identity and a canonical ID. Lists require explicit mappings; names are never fuzzy-matched.
- **Mutation** — An ordered, idempotent request to create, update, or delete a canonical resource/provider representation.
- **Provider adapter** — A boundary component that translates provider API semantics into and out of the provider-neutral contracts. Adapter URL validation prevents bearer credentials from being sent to unsafe origins.
- **Quarantine** — Durable storage for legacy records whose account ownership is missing, ambiguous, or contradictory. Quarantined payloads are excluded from account reads, and their canonical IDs remain reserved until an explicit repair.
- **Relay** — Optional HTTP deployment shell. In this repository it is stateless and has no authority to invent or retain sync state; `/healthz` is liveness only, while `/readyz` remains unavailable until a real backend is supplied.
- **Snapshot** — The last canonical representation observed for a mapping. It is the base used by three-way merge.
- **Tombstone** — Durable deletion metadata retained in the change history so offline clients cannot resurrect an older copy.
- **Three-way merge** — Comparison of base, local, and remote values. A field changes safely when only one side differs from base; concurrent differences remain conflicts.
