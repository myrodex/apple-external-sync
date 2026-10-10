# External Sync Apple apps

`AppleExternalSync.xcodeproj` contains the runnable SwiftUI application targets:

- **AppleExternalSync iOS** — iOS 16+, bundle identifier `com.myrodex.appleexternalsync.ios`, scheme `AppleExternalSync-iOS`.
- **AppleExternalSync macOS** — macOS 13+, bundle identifier `com.myrodex.appleexternalsync.macos`, scheme `AppleExternalSync-macOS`.

Both targets link the local Swift package products `ExternalSync` and `SyncAppSupport` from the repository root. The app targets own the device boundary: EventKit permissions, OAuth callback registration, background scheduling, SQLite Application Support storage, and macOS App Sandbox/network entitlements. The canonical model and sync algorithms remain in the root package targets documented in [`../../docs/architecture.md`](../../docs/architecture.md).

## Build from the repository root

```sh
xcodebuild \
  -project Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj \
  -scheme AppleExternalSync-iOS \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath .build/App-iOS \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj \
  -scheme AppleExternalSync-macOS \
  -sdk macosx \
  -configuration Debug \
  -derivedDataPath .build/App-macOS \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The checked-in project defaults `CODE_SIGNING_ALLOWED = NO`, `CODE_SIGNING_REQUIRED = NO`, and an empty signing identity. These commands intentionally validate compilation without a provisioning profile. They are **not** install, launch, archive, or distribution checks: an unsigned iOS app cannot be installed on a physical device or distributed, and an unsigned macOS build does not validate its App Sandbox/network entitlements. They also do not validate Keychain persistence, EventKit authorization, background execution, login-item registration, or OAuth callback delivery. For those checks, open the project in Xcode, select a development team, enable normal signing, and run the target on the intended simulator/device or macOS host.

The concrete `KeychainOAuthTokenStore` and `KeychainOAuthPendingAuthorizationStore` implementations are available only when the Apple `Security` framework is present. Portable package tests inject `InMemoryOAuthTokenStore`/`InMemoryOAuthPendingAuthorizationStore`; a non-Apple SwiftPM test run cannot prove device Keychain behavior. Do not treat a successful unsigned build or package test as evidence that entitlements or secure storage are configured for release.

## Local storage and account lifecycle

`ProductionSyncCoordinator` creates the default SQLite database at `Application Support/AppleExternalSync/sync.sqlite` (inside the app sandbox on iOS). The store partitions checkpoints and durable `sync_runs` by `(provider, accountID)`. On first open after the account-partitioning migration, the old singleton checkpoint is split using explicit ownership evidence. Records with missing or conflicting ownership are retained in `sync_state_quarantine`, omitted from account reads, and reserve their canonical IDs until an explicit repair. Disconnect removes the selected account's checkpoint and run history; the provider connection factory separately revokes/removes credentials from Keychain. Quarantined legacy records are not deleted by disconnect.

## Optional OAuth configuration

OAuth client IDs and stable authenticated account identifiers are deliberately not committed. Pass them as build settings or set them in an untracked `.xcconfig`. The account identifiers are provider-account-specific (for example a Google subject/email-derived stable identifier or Entra object ID), never the generic `device` placeholder:

```sh
xcodebuild \
  -project Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj \
  -scheme AppleExternalSync-iOS \
  -sdk iphonesimulator \
  EXTERNAL_SYNC_GOOGLE_CLIENT_ID='your-public-google-client-id' \
  EXTERNAL_SYNC_MICROSOFT_CLIENT_ID='your-public-entra-client-id' \
  EXTERNAL_SYNC_GOOGLE_ACCOUNT_ID='stable-google-account-id' \
  EXTERNAL_SYNC_MICROSOFT_ACCOUNT_ID='stable-entra-account-id' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The callback URL is `appleexternalsync://oauth/callback`, registered in both platform Info.plists. Refresh tokens and pending PKCE state/code verifiers remain in the platform Keychain; pending authorization entries expire after ten minutes and are cleaned up on startup. Client secrets must never be added to the app target. OAuth uses Authorization Code + PKCE and performs an account-identity check before persisting a token.

Custom REST can be enabled by setting `EXTERNAL_SYNC_REST_CONFIGURATION_JSON` to a complete declarative JSON configuration. The configuration supplies the HTTPS base URL, list/task JSON field maps, pagination, optional changes feed, and create/update/delete mutation paths; it never contains a bearer token. Example shape:

```json
{
  "accountID": "stable-rest-account-id",
  "keychainService": "dev.myrodex.external-sync.oauth",
  "configuration": {
    "baseURL": "https://sync.example.test",
    "lists": { "path": "/collections", "fields": { "id": "id", "title": "name" }, "pagination": { "mode": "cursor", "itemsPath": "items", "nextCursorPath": "next" } },
    "tasks": { "path": "/items", "fields": { "id": "id", "title": "name", "listID": "collectionId" }, "pagination": { "mode": "cursor", "itemsPath": "items", "nextCursorPath": "next" } },
    "listMutations": { "createPath": "/collections", "updatePath": "/collections/{id}", "deletePath": "/collections/{id}" },
    "taskMutations": { "createPath": "/items", "updatePath": "/items/{id}", "deletePath": "/items/{id}" }
  }
}
```

Its bearer token is read from the device Keychain using the configured service/account; the app never accepts or logs bearer tokens through the relay. Configuration validation requires an HTTPS base URL without embedded credentials and relative endpoint paths: absolute URLs, `//` host-relative paths, `?`/`#` injection, `.`/`..` traversal, backslashes, and control characters are rejected. Provider-supplied pagination links and Microsoft Graph delta links are followed only when they resolve to the configured HTTPS origin (same scheme, host, and effective port); unsafe links fail closed before credentials are sent.

## Platform runtime behavior

### iOS background refresh

The app registers `com.myrodex.appleexternalsync.refresh` with `BGTaskScheduler` and declares it in `BGTaskSchedulerPermittedIdentifiers`. `IOSBackgroundSyncScheduler` is only the one-shot task boundary; `AppleSyncLifecycle` owns the operation result and resubmits the next request after every foreground/background run. A failed sync or failed reschedule is reported as a failed background result instead of being treated as success. iOS controls the actual execution time and may defer refresh work.

### macOS login item

The default macOS configuration uses `SMAppService.mainApp`, so “Start sync when I log in” launches the main app at login. It does **not** claim to be a separate invisible helper and does not start a second sync engine. The Settings screen exposes whether the login item is enabled, whether macOS requires approval, and an “Open Login Items settings” action.

A bundled helper can be adopted later without changing the UI/runtime contract: set the app's `ExternalSyncLoginItemBundleIdentifier` Info.plist key to the helper bundle identifier and package that helper under `Contents/Library/LoginItems`. `MacOSLoginItemManager` then switches to `SMAppService.loginItem(identifier:)` and reports `LoginItemTarget.bundledHelper`; if the key is absent it explicitly reports `LoginItemTarget.mainApplication`.
