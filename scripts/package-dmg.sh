#!/bin/bash
set -euo pipefail

usage() {
    echo 'Usage: bash scripts/package-dmg.sh /path/to/Abbrio.app NOTARY_KEYCHAIN_PROFILE'
    echo 'Requires a Developer ID signed, notarized and stapled export from Xcode.'
    echo 'Set ABBRIO_SIGNING_IDENTITY and ABBRIO_DEVELOPMENT_TEAM for the release signer.'
}

if [[ "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi
if [[ $# -ne 2 ]]; then
    usage >&2
    exit 1
fi

fail() { echo "Error: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
profile="$2"
identity="${ABBRIO_SIGNING_IDENTITY:-}"
team="${ABBRIO_DEVELOPMENT_TEAM:-}"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'Set ABBRIO_DEVELOPMENT_TEAM to a 10-character Apple Team ID.'
identity_pattern="^Developer ID Application: .+ \($team\)$"
[[ ! "$identity" =~ [[:cntrl:]] && "$identity" =~ $identity_pattern ]] || fail 'Set ABBRIO_SIGNING_IDENTITY to a Developer ID Application certificate name ending in the configured Team ID.'
[[ -d "$app" ]] || fail 'The exported app does not exist.'
app="$(cd "$app" && pwd)"
plist="$app/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
[[ "$bundle_id" == 'com.zardozgroup.abbrio' ]] || fail 'Expected the Abbrio bundle identifier.'
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected a numeric major.minor.patch version.'
[[ "$executable" == 'Abbrio' ]] || fail 'Expected the Abbrio executable.'

codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$app"
architectures=" $(lipo -archs "$app/Contents/MacOS/$executable") "
[[ "$architectures" == *' arm64 '* && "$architectures" == *' x86_64 '* ]] || fail 'Expected both arm64 and x86_64 architectures.'
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

output="$repo_root/build/releases/$version"
[[ ! -e "$output" ]] || fail "Output already exists: $output. Preserve it or move it aside before retrying."
mkdir -p "$output"
staging=$(mktemp -d "${TMPDIR:-/tmp}/abbrio-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Abbrio.app"
ln -s /Applications "$staging/Applications"

dmg="$output/Abbrio-$version.dmg"
hdiutil create -volname Abbrio -srcfolder "$staging" -format UDZO "$dmg"
codesign --sign "$identity" --timestamp --identifier com.zardozgroup.abbrio.dmg "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

# Keep the submission result with the artifact so failures can be investigated.
notary_args=(--keychain-profile "$profile")
if [[ -n "${ABBRIO_NOTARY_KEYCHAIN:-}" ]]; then
    notary_args+=(--keychain "$ABBRIO_NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --output-format plist > "$output/notarization.plist"
status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$output/notarization.plist")
[[ "$status" == 'Accepted' ]] || fail "Notarization status: $status. See $output/notarization.plist."
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$output" && shasum -a 256 "Abbrio-$version.dmg" > "Abbrio-$version.dmg.sha256")
echo "Ready for installation testing: $dmg"
echo 'Nothing has been uploaded to GitHub.'
