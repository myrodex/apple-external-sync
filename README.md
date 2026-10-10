# Apple External Sync

Apple External Sync is a Swift 6 package and protocol for synchronizing Apple Reminders with provider-neutral lists and tasks. The canonical model keeps provider IDs, cursors, revisions, mappings, tombstones, and conflicts explicit so offline clients can converge without fuzzy matching or silent last-write-wins behavior.

## What is here

- `Sources/ExternalSync` — shared canonical models, identity mapping, changes, merge primitives, and current SwiftUI app-shell support.
- `Sources/SyncDomain` — domain state, conflicts, tombstones, and clocks.
- `Sources/SyncContracts` — adapter-facing provider contracts, capabilities, mutations, and errors.
- `Sources/SyncAdapters` — provider adapters and HTTP transport.
- `Sources/SyncEngine` — cursor-safe pull/push orchestration, deterministic three-way merges, conflict queueing, tombstone retention, and retry-safe cursor advancement.
- `Sources/SyncStore` — SQLite-backed, account-partitioned canonical sync checkpoints (`SyncStateStore`) plus durable sync-run history, the lower-level transactional `LocalStore` API, and in-memory test doubles. Production runtime uses SQLite; JSON-file state persistence is intentionally not provided.
- `Sources/SyncAppSupport` — production composition boundary; `SyncRuntime` wires `SyncEngine` to `SQLiteLocalStore` and keeps provider login device-only.
- `Apps/AppleExternalSyncApp` — runnable SwiftUI iOS and macOS application targets in `AppleExternalSync.xcodeproj`; each target links the local `ExternalSync` package product and owns platform permissions, OAuth callback registration, lifecycle/background scheduling, and packaging.
- `Relay/` — optional stateless Vapor deployment shell; it has no persistence or provider credentials.
- `schemas/`, `openapi/`, `examples/` — JSON Schema, OpenAPI, and wire-contract fixtures.

See [`docs/architecture.md`](docs/architecture.md) for package boundaries and data flow, [`docs/protocol.md`](docs/protocol.md) for normative wire behavior, and [`docs/openapi.md`](docs/openapi.md) for contract tooling.

## Requirements

- Swift 6.0 or newer for the root package (Swift 6.3 or newer for the optional Vapor relay).
- Python 3.10+ with `scripts/requirements.txt` for schema/example validation.
- Node.js 20+ and `npx` for OpenAPI linting/bundling. Swift client generation additionally requires Java 11+ through OpenAPI Generator.

## Verify locally

```sh
swift test --parallel
python3 -m venv .venv
.venv/bin/pip install -r scripts/requirements.txt
./scripts/validate_protocol.sh
./scripts/openapi.sh lint
```

Build the Apple application targets (Xcode 27 or newer):

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

The full app-target setup, signing notes, and optional public OAuth client configuration are documented in [`Apps/AppleExternalSyncApp/README.md`](Apps/AppleExternalSyncApp/README.md).

Run the stateless relay separately:

```sh
swift test --package-path Relay --parallel
swift run --package-path Relay
```

The relay's `/healthz` endpoint reports process liveness. `/readyz` and `/v1/capabilities` deliberately return a structured `503 not_configured` response because no durable, account-authorized backend is implemented. Device apps use `SyncRuntimeConfiguration(databaseURL:)`, which persists the complete account-scoped canonical checkpoint and durable run history in SQLite; disconnect removes only the selected provider account's sync state and credentials.

## Security and privacy

Read [`SECURITY.md`](SECURITY.md) and [`PRIVACY.md`](PRIVACY.md) before handling real provider accounts. Never commit credentials, provider exports, reminder content, or `.build` artifacts.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
