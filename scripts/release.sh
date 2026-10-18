#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 VERSION BUILD_NUMBER NOTARY_KEYCHAIN_PROFILE [RELEASE_NOTES.md]" >&2
    exit 1
fi

release_version="$1"
release_build="$2"
notary_profile="$3"
if [[ ! "$release_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$release_build" =~ ^[1-9][0-9]*$ ]]; then
    echo "Use a numeric version and a positive, increasing build number." >&2
    exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
team_id="${NBA_RELEASE_TEAM_ID:-E4Y8VJA2GT}"
bundle_id="com.nayeemrahman.NBAScoreTracker"
repository="https://github.com/nayeemrahman13/nba-score-track-mac"
release_tag="v${release_version}"
output_dir="$repo_root/dist/$release_tag"
if [[ -e "$output_dir" ]]; then
    echo "Release assets already exist at $output_dir. Use a new version or move those assets before rebuilding." >&2
    exit 1
fi
if [[ $# == 4 && ! -f "$4" ]]; then
    echo "Release notes file does not exist: $4" >&2
    exit 1
fi
mkdir -p "$repo_root/build"
work_dir="$(mktemp -d "$repo_root/build/release.XXXXXX")"
staging_dir="$work_dir/assets"
archive_path="$work_dir/NBAScoreTracker.xcarchive"
package_dir="$repo_root/build/SourcePackages"

# Check authentication before spending time on the archive.
xcrun notarytool history --keychain-profile "$notary_profile" --output-format json > "$work_dir/notary-history.json"

xcodebuild -project "$repo_root/NBAScoreTracker/NBAScoreTracker.xcodeproj" \
    -scheme NBAScoreTracker -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" -derivedDataPath "$work_dir/DerivedData" \
    -clonedSourcePackagesDirPath "$package_dir" -onlyUsePackageVersionsFromResolvedFile \
    "DEVELOPMENT_TEAM=$team_id" "MARKETING_VERSION=$release_version" "CURRENT_PROJECT_VERSION=$release_build" \
    archive > "$work_dir/archive.log" 2>&1 || { tail -n 60 "$work_dir/archive.log" >&2; exit 1; }

python3 - "$work_dir/ExportOptions.plist" "$team_id" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as handle:
    plistlib.dump({'method': 'developer-id', 'teamID': sys.argv[2],
                  'signingStyle': 'manual', 'signingCertificate': 'Developer ID Application'}, handle)
PY
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$work_dir/export" \
    -exportOptionsPlist "$work_dir/ExportOptions.plist" > "$work_dir/export.log" 2>&1 \
    || { tail -n 60 "$work_dir/export.log" >&2; exit 1; }

app_path="$work_dir/export/NBAScoreTracker.app"
python3 "$repo_root/scripts/verify_release.py" "$app_path" --team-id "$team_id"
ditto -c -k --keepParent "$app_path" "$work_dir/notarization.zip"
xcrun notarytool submit "$work_dir/notarization.zip" --keychain-profile "$notary_profile" \
    --wait --output-format json > "$work_dir/notarization.json"
python3 - "$work_dir/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    result = json.load(handle)
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization was not accepted. Submission: {result.get('id')}. Status: {result.get('status')}")
PY
xcrun stapler staple "$app_path"
python3 "$repo_root/scripts/verify_release.py" "$app_path" --team-id "$team_id" --notarized

mkdir -p "$staging_dir"
update_archive="$staging_dir/NBAScoreTracker-$release_version.zip"
ditto -c -k --keepParent "$app_path" "$update_archive"
if [[ $# == 4 ]]; then
    cp "$4" "$staging_dir/NBAScoreTracker-$release_version.md"
fi
sparkle_tools="$package_dir/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" --account "$bundle_id" \
    --download-url-prefix "$repository/releases/download/$release_tag/" \
    --maximum-versions 1 --maximum-deltas 0 --embed-release-notes "$staging_dir"
python3 "$repo_root/scripts/verify_release.py" "$app_path" --team-id "$team_id" --notarized \
    --appcast "$staging_dir/appcast.xml" --archive "$update_archive"
mkdir -p "$repo_root/dist"
mv "$staging_dir" "$output_dir"
echo "Release assets are ready in $output_dir"
echo "Archive and logs: $work_dir"
