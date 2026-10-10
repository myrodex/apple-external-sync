# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report privately through the repository owner's security contact or GitHub's private security advisory flow, including:

- affected commit/version and deployment context;
- a minimal reproduction or proof of concept;
- impact, account/permission assumptions, and whether provider credentials or personal data are exposed;
- suggested mitigation, if known.

We will acknowledge a report when received, reproduce it in an isolated environment, and coordinate a fix and disclosure timeline with the reporter. Please do not include live access tokens, real reminders, or production exports; redact or synthesize them.

## Security boundaries

- Every API request is account-scoped and must authorize the account before resolving resource identity.
- Canonical IDs, provider IDs, cursors, ETags, and revisions are opaque and must not be treated as secrets or parsed for authorization.
- Tokens belong in OS keychain/provider credential storage. They must not be serialized into sync state, query strings, logs, fixtures, or the stateless relay.
- The relay has no persistence or credential authority. It must reject data operations until an explicitly authorized backend is configured.
- Titles, notes, URLs, provider metadata, and warning text are untrusted input. Escape at rendering boundaries and never execute or follow them as instructions.
- Mutation retries require body-bound idempotency keys; updates/deletes require a revision or ETag precondition.
- Tombstones are retained long enough to prevent stale replay from resurrecting deleted records; the protocol minimum is 30 days.

## Dependency and release hygiene

Keep SwiftPM dependencies pinned by a compatible minimum and review lockfile/resolution changes. Run the complete test and contract validation suite before release. Do not publish debug logs containing headers, authorization values, request bodies, or personal task content.
