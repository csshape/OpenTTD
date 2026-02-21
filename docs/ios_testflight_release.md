# iPadOS TestFlight Release Runbook (Local Xcode Upload)

This runbook describes how to prepare an iPad-only OpenTTD build, archive it,
and upload it manually to TestFlight from Xcode.

## 1. Generate the iOS device project

Build the native host tool first:

```bash
cmake --preset macos-xcode-universal
cmake --build --preset macos-xcode-universal-tools-release
```

Then generate and build the iOS device project:

```bash
cmake --preset ios-device-xcode-release
cmake --build --preset ios-device-build-release
```

To override the bundle identifier at configure time:

```bash
cmake --preset ios-device-xcode-release -DOTTD_IOS_BUNDLE_IDENTIFIER=com.yourcompany.openttd
```

Open the generated project:

- `build/xcode-ios-device-release/openttd.xcodeproj`

Host tools and iOS archive both use `Release` in this flow, which avoids
missing `strgen` / `settingsgen` script errors during archive.

## 2. Configure signing and version in Xcode

In Xcode (`openttd` target, `Release` configuration):

1. Set `Signing & Capabilities`:
   - Team: your Apple Developer team
   - Signing Certificate: Apple Distribution
   - Provisioning Profile: automatic or your chosen profile
2. Confirm Bundle Identifier matches your App Store Connect app record.
3. Set version fields for this upload:
   - `Version` (`CFBundleShortVersionString`)
   - `Build` (`CFBundleVersion`) and ensure it is higher than the previous upload.

## 3. Build and archive

1. Select `Any iOS Device (arm64)` / `Generic iOS Device`.
2. Select scheme `openttd`.
3. Use `Product > Archive`.
4. Wait for Organizer to open with the new archive.

## 4. Upload to TestFlight

From Organizer:

1. Select the archive.
2. Click `Distribute App`.
3. Choose `App Store Connect`.
4. Choose `Upload`.
5. Keep defaults unless your account/process requires custom choices.
6. Complete upload and wait for processing in App Store Connect.

## 5. Verify in App Store Connect (Internal Testers)

1. Open App Store Connect > My Apps > your app > TestFlight.
2. Confirm the uploaded build appears after processing.
3. Assign build to internal tester group(s).

## Pre-upload checklist

- App icon catalog is present (`os/ios/Assets.xcassets/AppIcon.appiconset`).
- Bundle identifier is correct for the target app.
- Build number is incremented compared to previous TestFlight upload.
- Archive was created in `Release`.
- Xcode validation/upload shows no blocking signing or metadata errors.

## Troubleshooting

- If archive/build fails in `CompileAssetCatalogVariant ... Assets.xcassets` with
  `No available simulator runtimes for platform iphonesimulator`, install at
  least one iOS Simulator runtime in Xcode (`Settings > Platforms`) and retry.
- If Organizer shows an archive that is not an iOS app archive, verify:
  - You opened `build/xcode-ios-device-release/openttd.xcodeproj` (not the simulator project).
  - Scheme `openttd` archives with `Release`.
  - Destination is `Any iOS Device (arm64)` / `Generic iOS Device`.
  - `openttd` target has `Skip Install = No` for `Release`.
