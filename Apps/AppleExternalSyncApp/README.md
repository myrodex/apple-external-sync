# External Sync Apple apps

`AppleExternalSync.xcodeproj` contains the runnable SwiftUI application targets:

- **AppleExternalSync iOS** — iOS 16+, bundle identifier `com.myrodex.appleexternalsync.ios`.
- **AppleExternalSync macOS** — macOS 13+, bundle identifier `com.myrodex.appleexternalsync.macos`.

Both targets link the local Swift package product `ExternalSync` from the repository root. The app targets own the device boundary: EventKit permissions, OAuth callback registration, background scheduling, SQLite Application Support storage, and macOS App Sandbox/network entitlements.

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

For a device or distributable archive, open the project in Xcode, select a development team, and enable normal signing. The local build command disables signing only so it works on CI and simulator hosts without a provisioning profile.

## Optional OAuth configuration

OAuth client IDs are deliberately not committed. Pass them as build settings or set them in an untracked `.xcconfig`:

```sh
xcodebuild \
  -project Apps/AppleExternalSyncApp/AppleExternalSync.xcodeproj \
  -scheme AppleExternalSync-iOS \
  -sdk iphonesimulator \
  EXTERNAL_SYNC_GOOGLE_CLIENT_ID='your-public-google-client-id' \
  EXTERNAL_SYNC_MICROSOFT_CLIENT_ID='your-public-entra-client-id' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The callback URL is `appleexternalsync://oauth/callback`, registered in both platform Info.plists. Refresh tokens remain in the platform Keychain; client secrets must never be added to the app target.

Custom REST can be enabled by setting `EXTERNAL_SYNC_REST_CONFIGURATION_JSON` to a complete declarative JSON configuration. The configuration supplies the HTTPS base URL, list/task JSON field maps, pagination, optional changes feed, and create/update/delete mutation paths; it never contains a bearer token. Example shape:

```json
{
  "accountID": "device",
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

Its bearer token is read from the device Keychain using the configured service/account; the app never accepts or logs bearer tokens through the relay. The configuration is validated as HTTPS-only before the provider is exposed in the connection picker.

## Platform runtime behavior

### iOS background refresh

The app registers `com.myrodex.appleexternalsync.refresh` with `BGTaskScheduler` and declares it in `BGTaskSchedulerPermittedIdentifiers`. `IOSBackgroundSyncScheduler` is only the one-shot task boundary; `AppleSyncLifecycle` owns the operation result and resubmits the next request after every foreground/background run. A failed sync or failed reschedule is reported as a failed background result instead of being treated as success. iOS controls the actual execution time and may defer refresh work.

### macOS login item

The default macOS configuration uses `SMAppService.mainApp`, so “Start sync when I log in” launches the main app at login. It does **not** claim to be a separate invisible helper and does not start a second sync engine. The Settings screen exposes whether the login item is enabled, whether macOS requires approval, and an “Open Login Items settings” action.

A bundled helper can be adopted later without changing the UI/runtime contract: set the app's `ExternalSyncLoginItemBundleIdentifier` Info.plist key to the helper bundle identifier and package that helper under `Contents/Library/LoginItems`. `MacOSLoginItemManager` then switches to `SMAppService.loginItem(identifier:)` and reports `LoginItemTarget.bundledHelper`; if the key is absent it explicitly reports `LoginItemTarget.mainApplication`.
