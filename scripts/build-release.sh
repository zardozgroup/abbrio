#!/bin/bash
set -euo pipefail
umask 077

fail() { echo "Error: $*" >&2; exit 1; }

version="${1:-}"
[[ $# -eq 1 && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Usage: bash scripts/build-release.sh VERSION'
for setting in RUNNER_TEMP BUILD_CERTIFICATE_BASE64 P12_PASSWORD APPLE_ID APPLE_APP_SPECIFIC_PASSWORD \
    ABBRIO_DEVELOPMENT_TEAM ABBRIO_SIGNING_IDENTITY; do
    [[ -n "${!setting:-}" ]] || fail "$setting is required for the release build."
done

team="$ABBRIO_DEVELOPMENT_TEAM"
identity="$ABBRIO_SIGNING_IDENTITY"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail 'ABBRIO_DEVELOPMENT_TEAM must be a 10-character Apple Team ID.'
identity_pattern="^Developer ID Application: .+ \($team\)$"
[[ ! "$identity" =~ [[:cntrl:]] && "$identity" =~ $identity_pattern ]] \
    || fail 'ABBRIO_SIGNING_IDENTITY must be the full Developer ID Application certificate name for this team.'

cd "$(dirname "$0")/.."
work=$(mktemp -d "$RUNNER_TEMP/abbrio-release.XXXXXX")
certificate="$work/signing.p12"
keychain="$work/signing.keychain-db"
profile=Abbrio-notary
cleanup() {
    rm -f "$certificate"
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 -D > "$certificate"
keychains=("$keychain")
existing_keychains=$(security list-keychains -d user)
while IFS= read -r path; do
    keychains+=("$path")
done < <(printf '%s\n' "$existing_keychains" | sed -n 's/^[[:space:]]*"\(.*\)"$/\1/p')

keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign
rm -f "$certificate"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
security list-keychains -d user -s "${keychains[@]}"

certificate_hash=$(security find-identity -v -p codesigning "$keychain" \
    | awk -v name="\"$identity\"" '$0 ~ /[[:space:]]"/ && substr($0, index($0, "\"")) == name { print $2 }')
[[ "$certificate_hash" =~ ^[0-9A-Fa-f]{40}$ ]] || fail 'The Keychain must contain one valid matching Developer ID identity and private key.'

xcrun notarytool store-credentials "$profile" --keychain "$keychain" --team-id "$team" \
    --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
unset BUILD_CERTIFICATE_BASE64 P12_PASSWORD APPLE_ID APPLE_APP_SPECIFIC_PASSWORD keychain_password

archive="$work/Abbrio.xcarchive"
xcodebuild -project Abbrio.xcodeproj -scheme Abbrio -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath "$work/DerivedData" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp archive

export_options="$work/ExportOptions.plist"
plutil -create xml1 "$export_options"
plutil -insert method -string developer-id "$export_options"
plutil -insert destination -string export "$export_options"
plutil -insert signingStyle -string manual "$export_options"
plutil -insert signingCertificate -string "$certificate_hash" "$export_options"
plutil -insert teamID -string "$team" "$export_options"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$export_options"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" -exportOptionsPlist "$export_options"

app="$work/export/Abbrio.app"
archived_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$archived_version" == "$version" ]] || fail "Expected app version $version, got $archived_version."
codesign --verify --deep --strict --all-architectures "$app"
ditto -c -k --keepParent "$app" "$work/Abbrio.zip"
xcrun notarytool submit "$work/Abbrio.zip" --keychain-profile "$profile" --keychain "$keychain" \
    --wait --timeout 30m --output-format plist > "$work/app-notarization.plist"
status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/app-notarization.plist")
submission=$(/usr/libexec/PlistBuddy -c 'Print :id' "$work/app-notarization.plist")
[[ "$status" == Accepted ]] || fail "App notarization status: $status (submission $submission)."
xcrun stapler staple "$app"

ABBRIO_NOTARY_KEYCHAIN="$keychain" bash scripts/package-dmg.sh "$app" "$profile"
