# Releasing Blockfall

Blockfall releases are Apple Silicon-only and require macOS 14 or newer.

## One-time Apple setup

1. Install a **Developer ID Application** certificate and its private key in
   Keychain Access.
2. Create an app-specific password for the Apple ID used for notarization.
3. Save the credentials in Keychain (never in this repository):

   ```bash
   xcrun notarytool store-credentials blockfall-notary \
     --apple-id "APPLE_ID" --team-id "TEAM_ID" --password "APP_PASSWORD"
   ```

Confirm that the signing identity is available:

```bash
security find-identity -v -p codesigning
```

## Build a release DMG

`CFBundleVersion` must increase for every published build, including rebuilds
of the same user-facing version.

```bash
VERSION=0.1.0 BUILD_NUMBER=100 ./ci/package.sh
```

The script builds the app, signs it with the first available Developer ID
Application identity, creates `dist/Blockfall-0.1.0.dmg`, notarizes it, staples
Apple's ticket, and validates the result. Override `SIGN_IDENTITY` or
`NOTARY_PROFILE` when the defaults are not appropriate.

Issue: #329
