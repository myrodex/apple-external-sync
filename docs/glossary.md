# Glossary

- **Account scope** — The authenticated provider/sync account boundary. Every canonical resource, mapping, cursor, mutation, and conflict is authorized against exactly one account.
- **Canonical ID** — An ID assigned by the sync service to a provider-neutral list or task. It is not a provider's remote ID and is not a credential.
- **Cursor** — An opaque checkpoint for one account and one changes-feed filter. Clients persist only the server-returned next cursor.
- **ETag / revision** — Server/provider version metadata used for compare-and-swap writes. Clients treat both as opaque.
- **External identity** — The tuple identifying a provider object (`source`, entity type, and provider ID).
- **Field loss** — A provider cannot represent a submitted field exactly. The operation is rejected unless the caller explicitly accepts loss; accepted loss yields a warning.
- **LocalStore** — The persistence protocol used by the sync engine. SQLite is the production implementation; an in-memory implementation supports deterministic tests.
- **Mapping** — Durable association between an external identity and a canonical ID. Lists require explicit mappings; names are never fuzzy-matched.
- **Mutation** — An ordered, idempotent request to create, update, or delete a canonical resource/provider representation.
- **Provider adapter** — A boundary component that translates provider API semantics into and out of the provider-neutral contracts.
- **Relay** — Optional HTTP deployment shell. In this repository it is stateless and has no authority to invent or retain sync state.
- **Snapshot** — The last canonical representation observed for a mapping. It is the base used by three-way merge.
- **Tombstone** — Durable deletion metadata retained in the change history so offline clients cannot resurrect an older copy.
- **Three-way merge** — Comparison of base, local, and remote values. A field changes safely when only one side differs from base; concurrent differences remain conflicts.
