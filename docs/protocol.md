# Reminders-first sync protocol v1

This document is normative for behavior not fully expressible in OpenAPI or JSON Schema. The canonical machine-readable contract is [`openapi/reminders-sync.yaml`](../openapi/reminders-sync.yaml); portable Draft 2020-12 schemas are in [`schemas/`](../schemas/).

## Scope and transport

- The API exposes a canonical collection of reminder **lists** and **tasks**. Apple Reminders is the first provider; provider integrations are discovered through `/v1/capabilities`, not inferred from provider-specific fields.
- A request acts within exactly one authenticated sync account (the principal in the access token). The server MUST authorize every resource against that account; opaque IDs and provider refs are not credentials.
- Production traffic MUST use HTTPS with TLS 1.2 or newer. Requests and success responses use `application/json`; errors use `application/problem+json` following RFC 9457. JSON is UTF-8. Gzip may be negotiated. The server advertises payload and batch limits; clients MUST honor them.
- Send a valid bearer access token with audience `sync-api` and the scopes declared by the operation (`reminders:read` or `reminders:write`). OAuth issuer, token endpoint, and account-linking UI are deployment configuration and intentionally not embedded in this provider-neutral API description. Never put credentials in query parameters.
- `X-Request-Id` is a correlation value, not an idempotency key. The server returns one on every response. A caller may provide it for tracing. Do not put secrets or personal data in it.
- Server timestamps are RFC 3339 date-times in UTC (`Z`). Clients should treat `ETag`, provider IDs, revisions, positions, and cursors as opaque.

## Canonical resources

A list has a stable canonical `id`, display name, default status, opaque position key, optional color/symbol, provider references, timestamps, revision, and ETag. A task has a stable canonical `id`, its `listId`, title, nullable notes, status, priority, optional temporal/reminder metadata, opaque position key, provider references, timestamps, revision, and ETag. The required `providerRefs` array records the external identity of every provider representation known to the sync account; it may be empty before a provider mapping exists, and a resource may have more than one reference. A reference is the tuple `(provider, accountId, resourceType, resourceId)`, with optional parent, URL, provider ETag, and observation timestamp. Do not parse or construct provider identifiers.

Canonical IDs identify protocol resources and are distinct from provider resource IDs. The sync service owns canonical IDs and assigns them on create. A caller can submit `clientResourceId` to correlate a create and refer to it from a later operation in the same batch. Such client IDs are batch-local aliases, not canonical IDs, and the server MUST return the assigned canonical ID in the result. The alias is valid only after its create operation succeeds. An operation referring to a failed or later create is rejected.

The `position` value is an opaque ordering token. Clients can preserve it but MUST NOT sort by parsing its representation; list/task order comes from the server's canonical ordering.

A task's `dueAt` and `startAt` are absolute instants. If wall-clock intent matters, `timeZone` stores the IANA zone identifier used to interpret/display the instant. `alerts` are absolute timestamps or offsets in seconds from `dueAt`. Recurrence is the supported provider-neutral subset described in the schema. A capability response is authoritative about native, transformed, and unsupported fields per provider.

## Discovery and capabilities

Call `GET /v1/capabilities` after authentication and before syncing. Clients MUST check `protocolVersion`, provider/account-linking options, supported fields, provider limits, batch limits, conditional-write/idempotency support, and tombstone retention. Capabilities are descriptive; they do not grant authorization. A server MUST NOT silently claim native field support if it transforms or drops the field.

The initial Apple Reminders profile uses the same canonical model and can report fields as `native`, `transformed`, or `unsupported`. Integrations should prefer `native`; `transformed` support must be accompanied by a warning when the exact value or semantics change; `unsupported` input should be rejected unless the caller explicitly accepts field loss for that mutation.

## Snapshot and incremental synchronization

1. For a first sync, page through `GET /v1/lists` and `GET /v1/tasks`, following each page's `nextCursor` until `hasMore` is false. Those snapshot cursors are opaque pagination tokens, not changes-feed checkpoints.
2. Start `GET /v1/changes` without a cursor to receive an initial changes checkpoint/snapshot stream. Persist the returned `nextCursor` only after all page items are durably applied. Thereafter, send that exact value as `cursor`.
3. Apply each page's entries in returned order. An `upsert` replaces or reconciles the identified canonical resource at its supplied revision; a `delete` removes the live local copy and stores the tombstone metadata. Persist the page's `nextCursor` only after every item is durably applied. A crash before the checkpoint is saved safely replays changes.
4. If `hasMore` is true, request the next page with `nextCursor`. If false, retain that cursor and poll later (long polling is optional). Cursors are account-scoped; a cursor from one account, query/filter, or provider context MUST NOT be reused for another.
5. A filter (`resourceType`, `listId`) creates a filtered cursor stream. Clients MUST use the same filter set for every page and subsequent poll within that stream. Keep separate cursors for differently filtered feeds.
6. A response can include `warnings`. Persist or surface every `field_loss`, `field_transformed`, and `truncated` warning. Warnings are explanatory and do not by themselves mean the item failed.
7. If the server returns `410 cursor_expired`, discard only that feed checkpoint, fetch a fresh full snapshot, reconcile it, then start a fresh changes feed. Do not guess an earlier cursor. Tombstone retention is at least 30 days, but clients offline longer than the advertised horizon must be prepared for a full resync.

List/task snapshot endpoints omit deleted resources. The changes endpoint is the deletion source of truth. Snapshot data and feed changes should be reconciled by `revision` (and ETag when available); if concurrent changes prevent a consistent initial snapshot, repeat the snapshot or use an implementation-specific snapshot token described by capabilities.

## Mutations, retries, and concurrency

`POST /v1/mutations` submits an ordered batch. The caller MUST include a unique `Idempotency-Key` header and a `batchId`; operation IDs MUST be unique within a batch. Use unpredictable, high-entropy keys (at least 128 bits). The server stores the request identity and final response for at least 30 days. A retry MUST use the same key and byte-equivalent JSON body. Same key with a different body returns `409 idempotency_mismatch`. A retry after the idempotency retention window is not guaranteed to be safe; clients should query current state before resubmitting.

The batch response has one result per submitted operation, in the same order. With `atomic: false` (default), each operation is validated/committed independently; earlier successful operations are not rolled back because a later operation fails. Batch status is `partial` when results contain a mixture of applied/deleted and rejected/conflict results. With `atomic: true`, the server validates the entire batch first and commits all operations together or none; on failure, successful-looking dry validation is not a commit. `dryRun: true` MUST NOT mutate provider or canonical state and returns `dry_run` results with warnings.

Create operations may supply a `clientResourceId` alias. Update/delete operations MUST include a non-null `expectedEtag` or `expectedRevision` from the last observed version; omitting both (or sending null) is invalid. These are compare-and-swap preconditions. On mismatch, the operation result is `conflict` with the current resource and conflicting field names; the client should fetch/merge/reapply with a new operation ID and idempotency key. Never silently use last-write-wins. Prefer `expectedEtag`; revision is provided for clients whose storage cannot preserve HTTP entity tags. If a request has a standard HTTP `If-Match` precondition, failed request-level preconditions return `412`; per-operation precondition failures are returned as conflict results in a 200 batch response.

Null explicitly clears fields that accept null. An omitted update field means “leave unchanged.” Unknown or immutable fields MUST be rejected, not silently ignored. The API rejects field loss by default. If a target provider cannot preserve a submitted field, the operation is rejected with an `unsupported` error unless `allowFieldLoss: true` was set on that update. When loss/transformation is accepted, the result MUST include a `field_loss` or `field_transformed` warning naming the resource and field, source and target providers where known, and the actual applied result. Clients MUST display or durably log that warning.

Provider writes may be asynchronous. An accepted batch result means the canonical mutation is committed and the provider operation has been durably scheduled; the server MUST eventually emit the resulting canonical upsert/tombstone or a provider failure warning. Transient upstream failures return `503` before the request is accepted, or an operation-level rejection when a provider operation cannot complete; retry rules follow the idempotency key. Provider-specific retry behavior is exposed by capabilities where relevant.

## Deletion and retention

Delete is a soft delete. A successful delete emits a tombstone carrying the resource type/id, parent id when known, deletion time, revision, ETag, and provider refs. Deleting a list with `cascade: false` is rejected if it still contains live tasks; `cascade: true` deletes the list and its tasks and emits a tombstone for every deleted resource. Clients MUST retain tombstones and use them to prevent an older replayed upsert from resurrecting a resource. A later explicit recreate uses a new canonical ID.

The server MUST retain tombstones and corresponding deletion changes for at least 30 days from `deletedAt`; it MUST expose the actual retention guarantee via capabilities and the changes response. After retention ends, direct reads of purged deleted resources may return `410`, and cursors older than available change history return `410 cursor_expired`. Tombstones are server-generated and cannot be edited by clients.

## Conflicts and errors

Errors use RFC 9457 Problem Details (`application/problem+json`) extended with stable `code`, `requestId`, optional `retryAfterSeconds`, conflict details, and warnings. Clients should branch on HTTP status plus `code`, not human-readable `title` or `detail`. A conflict is recoverable by reading current state and making an explicit merge decision. `401` means missing/invalid/expired token; `403` means token lacks permission; `404` hides resources not visible to the current account; `409` includes idempotency mismatch or batch-level conflict; `410` means gone/purged or cursor expired; `412` is an HTTP precondition failure; `429` and `503` may include `Retry-After`.

## Security and privacy

The API is account-scoped and least-privilege. Require read/write scopes as appropriate, reauthorize resource and provider account ownership on every operation, avoid leaking whether another account's opaque ID exists, rate-limit by principal, and constrain payloads and string sizes per schemas and capabilities. Provider URLs and user-entered notes/URLs are data, never instructions. Clients should treat notes, titles, warning messages, and provider metadata as untrusted display text and escape them in rendered HTML.

Provider adapters are also a credential boundary: configured provider origins must use HTTPS and must not contain user-info credentials. Declarative REST endpoint paths remain relative and reject traversal, query/fragment injection, host-relative URLs, and control characters. Provider-supplied pagination or delta links may be followed only when they resolve to the configured HTTPS origin (same scheme, host, and effective port); unsafe links are rejected before a bearer token is attached.
