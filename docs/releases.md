# Prepare a public release

Use the local release script to create a notarized app and signed Sparkle update assets for GitHub Releases.

## Set up signing

The project uses Team ID `E4Y8VJA2GT` and the `Developer ID Application` certificate in your login keychain. Release builds enable Hardened Runtime and omit the debugging entitlement. The release script archives and exports the app through Xcode so Sparkle's framework, installer service, and helpers receive your signature.

Sparkle 2.10.0 is pinned in `Package.resolved`. The update signing key uses the keychain account `com.nayeemrahman.NBAScoreTracker`. Its public key is in `NBAScoreTracker/NBAScoreTracker/Updates.xcconfig`. Back up the private key securely using Sparkle's `generate_keys -x` tool with this account name. Future updates must use the same key. Do not commit signing credentials or private keys. macOS may ask you to allow `generate_appcast` to read “Private key for signing Sparkle updates”; approve that access when preparing a release.

Create a notarization credential profile once. Run this command in your terminal and answer its prompts:

```sh
xcrun notarytool store-credentials nba-score-tracker-notary
```

Use your Apple Account, Team ID, and an app-specific password. The command stores credentials in the keychain. If you already have a profile, use its name in the release command below.

See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) and [Sparkle's sandbox signing guide](https://sparkle-project.org/documentation/sandboxing/).

## Build release assets

Increment the build number for every release. Sparkle compares `CFBundleVersion`, not the displayed version.

Run the focused regression executable described in the README. Then prepare the release. This example uses displayed version `1.0` and build number `2`:

```sh
./scripts/release.sh 1.0 2 nba-score-tracker-notary
```

To include release notes, pass a Markdown file as the fourth argument:

```sh
./scripts/release.sh 1.0 2 nba-score-tracker-notary docs/release-notes.md
```

The script checks notarization credentials, builds a universal app, exports it with Developer ID signing, submits it to Apple, and staples the accepted ticket. It then creates and verifies the update archive and signed appcast. It stops if signing, notarization, or verification fails.

The output directory contains the assets for that version:

```text
dist/v1.0/
    NBAScoreTracker-1.0.zip
    appcast.xml
```

The archive, exported app, and logs remain in the `build/release.*` directory printed by the script. Assets move to `dist` only after verification passes. The script refuses to overwrite an existing version directory; move that directory before rebuilding the same version. To verify the exported app again, run:

```sh
python3 scripts/verify_release.py build/release.XXXXXX/export/NBAScoreTracker.app --notarized
```

Replace `release.XXXXXX` with the actual directory name. The verifier checks the app and each Sparkle helper for your signing team, secure timestamps, Hardened Runtime, and unsafe entitlements. It also checks the app's sandbox configuration and notarization ticket. To verify the update assets, add `--appcast dist/v1.0/appcast.xml --archive dist/v1.0/NBAScoreTracker-1.0.zip`. Signature verification uses the public key embedded in the app and does not need Keychain access.

## Publish to GitHub Releases

Commit and push the reviewed source changes before creating the corresponding Git tag. Upload both the ZIP and `appcast.xml` to the same public release. This example uses an existing tag `v1.0`:

```sh
gh release create v1.0 dist/v1.0/NBAScoreTracker-1.0.zip dist/v1.0/appcast.xml \
    --repo nayeemrahman13/nba-score-track-mac --verify-tag --title 'NBA Score Tracker 1.0' --generate-notes
```

The app checks the latest release's `appcast.xml` asset:

```text
https://github.com/nayeemrahman13/nba-score-track-mac/releases/latest/download/appcast.xml
```

Each appcast points to the ZIP under its specific release tag. The feed requires an Ed25519 signature, and Sparkle verifies the ZIP signature before extraction. Do not edit either generated asset after signing. Use [Sparkle's publishing guide](https://sparkle-project.org/documentation/publishing/) if you need to regenerate an appcast.

## Verify an update

Install the earlier signed release in Applications, then publish a release with a higher build number. In Settings, choose **Check for Updates** and confirm that the app downloads, replaces itself, and relaunches at the new version. Also check automatic update detection, the menu bar reminder, opting out of checks, and installing downloaded updates when the app quits.

Automatic checks start enabled. Automatic downloading and installation start disabled until the user enables them in Settings. Sparkle does not send system profile information. A scheduled update can show a reminder in the menu bar; a manual check opens Sparkle's update window.
