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

Custom REST can be enabled by setting `EXTERNAL_SYNC_REST_BASE_URL` to an HTTPS base URL. Its token is read from the device Keychain under the `genericREST:device` account; the app never accepts or logs bearer tokens through the relay.
