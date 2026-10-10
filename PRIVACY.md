# Privacy notes

This project is a synchronization library and protocol, not a data broker. Deployments must document their own legal basis, retention, processor relationships, and regional requirements.

## Data minimization

- The canonical model contains only fields needed to synchronize reminder lists/tasks, provider identity metadata, timestamps, revisions, cursors, conflicts, and deletion tombstones.
- Provider credentials and refresh tokens remain in platform keychain facilities and are never part of canonical sync records.
- Logs should contain request IDs, status, and timing—not titles, notes, URLs, tokens, or full provider payloads.
- Examples and tests use synthetic data. Never commit real reminders or account identifiers.

## Local-first behavior

On-device app targets may keep sync state in the local store selected by the user/device. A local store must support deletion and retention cleanup. The optional relay scaffold is stateless: it does not retain requests, reminders, credentials, or analytics by default.

## Account isolation and deletion

Server implementations must authorize every operation against the authenticated account, avoid cross-account existence leaks, and define how a user disconnects a provider. Disconnect flows should revoke provider credentials where supported, remove account mappings and sync state, and retain only records required by a documented legal or audit obligation.

Protocol tombstones exist to converge offline clients; they are not permission to retain reminder content indefinitely. A deployment must publish its actual retention period and purge policy, subject to applicable law and user requests.
