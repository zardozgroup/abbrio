# Distributing Abbrio

Releases are universal macOS apps signed with Developer ID, delivered as notarized disk images.
Build and export in Xcode; use the local packaging script for the disk image. The script submits
the disk image to Apple but never commits, tags, pushes or uploads to GitHub.

## Prepare the app

1. Run the tests and choose the source revision for the release. Include all intended changes in that
   revision before archiving, so the eventual release tag describes the distributed app.
2. Set the app's marketing version (for example, `1.0.0`) and increment its build number as appropriate.
3. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and replace `YOURTEAMID`
   with your Apple Team ID. This ignored file enables automatic development signing for the archive;
   the distribution export below uses Developer ID signing. Keep the shared project settings unchanged.
   In Xcode, select the Abbrio scheme. Check the Release configuration uses standard architectures
   (`arm64` and `x86_64`) with Build Active Architecture Only set to No. Keep hardened runtime enabled,
   App Sandbox disabled, and the deployment target at macOS 14.
4. Choose Product → Archive. In Organizer, choose Distribute App and the direct distribution workflow
   using Developer ID Application signing for your release team. Submit for notarization, wait for
   acceptance, and export the notarized app. Labels vary by Xcode version; use Custom → Developer ID
   if needed. Do not package a development build from DerivedData.
5. Ensure the exported app has its ticket attached with `xcrun stapler staple /path/to/Abbrio.app`.

Keep the archive for debugging crash reports. Espanso is installed separately and is not included.

## Configure notarization credentials once

The Mac needs the Developer ID Application certificate and its private key in Keychain.
Create a notarytool Keychain profile interactively:

```sh
xcrun notarytool store-credentials Abbrio-notary
```

Enter your Apple account, an app-specific password, and your Apple Team ID when prompted.
Keep credentials in Keychain, never in scripts or the repository.

## Package the export

Set the release signer's Team ID and full Developer ID Application certificate name in your shell,
using the values from your own Keychain. The examples below are placeholders. The Team ID must match
the certificate name and the exported app's signature. Keep these settings outside tracked files;
the script does not read the local Xcode configuration.

From the repository root:

```sh
export ABBRIO_DEVELOPMENT_TEAM='YOURTEAMID'
export ABBRIO_SIGNING_IDENTITY='Developer ID Application: Your Organization (YOURTEAMID)'
bash scripts/package-dmg.sh /path/to/Abbrio.app Abbrio-notary
```

Both variables are required. Missing or malformed values stop the script before packaging or
notarization. The notarization profile remains in Keychain.

The script checks the bundle identifier, distribution signature, team, both architectures, and app
notarization. It creates a compressed DMG containing Abbrio and an Applications shortcut, signs it,
submits it to Apple, requires acceptance, staples and verifies the ticket, and calculates a SHA-256
checksum. It does not launch the app or access Espanso configuration.

Outputs go to `build/releases/<version>/`, which is ignored by Git. Existing output directories are
never overwritten. On failure, inspect `notarization.plist` if present; its submission ID can be used
with `xcrun notarytool log <id> --keychain-profile Abbrio-notary`. Preserve or move aside the output
directory before retrying. Only use artifacts from a run that completed successfully.

## Verify and publish

1. Mount the DMG, drag the app to Applications, and verify it launches on a clean test Mac or account.
   Test macOS 14 and both CPU architectures before claiming support. For functional development
   checks, launch with a throwaway configuration using `ABBRIO_CONFIG_TEMPLATE` or `ABBRIO_CONFIG_DIR`;
   never use the owner's real configuration without explicit authorization.
2. After an explicit decision to publish, push the approved source and create a version tag such as
   `v1.0.0` at the exact archived revision. Draft a GitHub Release for that tag.
3. Attach `Abbrio-<version>.dmg` and its `.sha256` file as release assets. Include macOS 14+, the separate
   Espanso 2.x prerequisite, drag-to-Applications instructions, and changes for this version.
4. Publish when ready. Download the published DMG through a browser and confirm normal Gatekeeper
   installation and launch on a clean test system. Do not bypass quarantine or Gatekeeper for this check.

## References

- [Apple: Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple: Customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub: Managing releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
