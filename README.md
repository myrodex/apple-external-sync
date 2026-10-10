# Apple External Sync

Apple External Sync is a Swift 6 package and protocol for synchronizing Apple Reminders with provider-neutral lists and tasks. The canonical model keeps provider IDs, cursors, revisions, mappings, tombstones, and conflicts explicit so offline clients can converge without fuzzy matching or silent last-write-wins behavior.

## What is here

- `Sources/SyncDomain` (`SyncDomain`) — canonical list/task values, ownership, clocks, tombstones, conflicts, and merge primitives.
- `Sources/SyncContracts` (`SyncContracts`) — provider-neutral adapter contracts, capabilities, mutations, and errors.
- `Sources/SyncAdapters` (`SyncAdapters`) — EventKit, Google Tasks, Microsoft Graph, generic REST, OAuth, and HTTP transport adapters.
- `Sources/SyncEngine` (`SyncEngine`) — account-scoped pull/push orchestration, deterministic three-way merges, conflict queueing, tombstone retention, and retry-safe cursor advancement.
- `Sources/SyncStore` (`SyncStore`) — SQLite-backed, account-partitioned canonical sync checkpoints (`SyncStateStore`), durable sync-run history, the lower-level compatibility/query `LocalStore` API, and in-memory test doubles. Production runtime uses account-partitioned `SyncStateStore` rows; historical `LocalStore` tables are not the authorization boundary. JSON-file state persistence is intentionally not provided.
- `Sources/SyncAppSupport` (`SyncAppSupport`) — production runtime composition and Apple lifecycle integration. `SyncRuntime` wires `SyncEngine` to `SQLiteLocalStore` and keeps provider login device-only.
- `Sources/ExternalSync` (`ExternalSync`; app-shell sources are under `AppShell/`) — the shared SwiftUI app shell, provider connection factories, settings, and production coordinator. It is not where the canonical domain model lives.
- `Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj` — runnable SwiftUI application targets `AppleExternalSync iOS` and `AppleExternalSync macOS`, with schemes `AppleExternalSync-iOS` and `AppleExternalSync-macOS`. The project links the local `ExternalSync` and `SyncAppSupport` products and owns platform permissions, OAuth callback registration, lifecycle/background scheduling, and packaging.
- `Relay/` — optional stateless Vapor deployment shell; it has no persistence or provider credentials.
- `schemas/`, `openapi/`, `examples/` — JSON Schema, OpenAPI, and wire-contract fixtures.

See [`docs/architecture.md`](docs/architecture.md) for exact target boundaries and data flow, [`docs/protocol.md`](docs/protocol.md) for normative wire behavior, and [`docs/openapi.md`](docs/openapi.md) for contract tooling.

## Requirements

- Swift 6.0 or newer for the root package (Swift 6.3 or newer for the optional Vapor relay).
- Python 3.10+ with `scripts/requirements.txt` for schema/example validation.
- Node.js 20+ and `npx` for OpenAPI linting/bundling. Swift client generation additionally requires Java 11+ through OpenAPI Generator.
- Xcode 27 or newer to build the checked-in application project. The package itself can be tested with SwiftPM on supported platforms, but the Apple app targets require Apple SDKs.

## Verify locally

```sh
swift test --parallel
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements.txt
./scripts/validate_protocol.sh
./scripts/openapi.sh lint
```

Build the Apple application targets from the repository root:

```sh
xcodebuild -project Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj \
  -scheme AppleExternalSync-iOS -sdk iphonesimulator \
  -configuration Debug -derivedDataPath .build/App-iOS \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj \
  -scheme AppleExternalSync-macOS -sdk macosx \
  -configuration Debug -derivedDataPath .build/App-macOS \
  CODE_SIGNING_ALLOWED=NO build
```

These commands intentionally produce unsigned compile artifacts. They are suitable for CI and SDK/build verification only: an unsigned build cannot be installed on a physical iOS device or distributed, and it does not prove that provisioning, code-signature entitlements, Keychain access, EventKit authorization, background scheduling, macOS login-item registration, or OAuth callback delivery work. Use a normally signed Xcode build with a development team and the appropriate runtime for those checks. The app's concrete Keychain stores are available only on Apple platforms; package tests use injected in-memory stores where secure platform services are unavailable.

The full app-target setup, signing limitations, Keychain storage, and optional public OAuth client configuration are documented in [`Apps/AppleExternalSyncApp/README.md`](Apps/AppleExternalSyncApp/README.md).

Run the stateless relay separately:

```sh
swift test --package-path Relay --parallel
swift run --package-path Relay
```

The relay's `/healthz` endpoint reports process liveness. `/readyz` and `/v1/capabilities` deliberately return a structured `503 not_configured` response because no durable, account-authorized backend is implemented. No production deployment manifest or hosting configuration is checked in; a deployment must provide HTTPS/TLS termination, process/port supervision, durable account authorization and persistence, provider credential handling, retention/purge policy, and observability before enabling data routes. Device apps currently sync directly through their injected provider adapters and local SQLite state; the relay is optional and not a hidden persistence service.

Shared runtime consumers use `SyncRuntimeConfiguration(databaseURL:)`; the production Apple app coordinator defaults to `Application Support/AppleExternalSync/sync.sqlite` (inside the app sandbox on iOS). SQLite stores one checkpoint per provider account and migrates the old shared checkpoint on first open. Records with missing or conflicting ownership are retained in a quarantine table, excluded from account reads, and permanently reserve their canonical IDs until an explicit repair. Disconnect removes only the selected account's checkpoint/run history; provider credentials are revoked/removed separately from Keychain, while quarantined records remain reserved.

## Security and privacy

Read [`SECURITY.md`](SECURITY.md) and [`PRIVACY.md`](PRIVACY.md) before handling real provider accounts. Never commit credentials, provider exports, or `.build` artifacts.

Provider URL safety is enforced at adapter boundaries: configured provider origins must use HTTPS and contain no embedded credentials; generic REST endpoint paths are relative and reject traversal, query/fragment injection, host-relative URLs, and control characters; provider-supplied pagination/delta links are accepted only when HTTPS and same-origin. Rejected links fail before bearer credentials are sent. Custom REST configuration contains no bearer token—the app resolves it from Keychain by provider/account.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
