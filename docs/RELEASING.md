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

## Sparkle updates through GitHub Releases

Sparkle 2.9.4 is pinned by SwiftPM. Its private EdDSA key is stored in the login
Keychain under the `blockfall` account; only the public key is committed. Back
up the private key somewhere secure:

```bash
app/.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account blockfall -x ~/Desktop/blockfall-sparkle-private-key
```

Delete or securely move the exported file immediately after backing it up.
Never commit it.

The application reads its feed from the latest GitHub Release asset:

```text
https://github.com/royashbrook/blockfall/releases/latest/download/appcast.xml
```

The repository therefore must remain public, and published updater releases
must be normal releases marked latest—not drafts or prereleases.

## Publish

Commit and push the exact source revision first, then run:

```bash
VERSION=0.1.0 BUILD_NUMBER=100 ./ci/release.sh
```

For the next builds, increment both values, for example `0.1.1` / `101`, then
`0.1.2` / `102`. The script refuses dirty tracked files, builds and notarizes
the DMG, generates an EdDSA-signed `appcast.xml`, and publishes both files as a
GitHub Release.

Before announcing a release:

1. Install its DMG on a different Apple Silicon Mac running macOS 14 or newer.
2. Launch normally without using right-click/Open.
3. Confirm **Blockfall → Check for Updates…** reaches the GitHub feed.
4. Publish a higher test build and confirm Sparkle downloads, installs, and
   relaunches it without losing worlds or settings.

Issue: #328
