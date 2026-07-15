#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
team_id="${DEVELOPMENT_TEAM:-}"
derived_data="${DERIVED_DATA_PATH:-$root/.build-sidestore}"
output="${1:-$root/Artifacts/VibeStation5-SideStore.ipa}"

if [[ -z "$team_id" ]]; then
    echo "Set DEVELOPMENT_TEAM to an Apple Development team ID." >&2
    echo "Example: DEVELOPMENT_TEAM=ABCDE12345 $0" >&2
    exit 2
fi

if [[ "$output" != /* ]]; then
    output="$root/$output"
fi

cd "$root"
xcodegen generate
xcodebuild -quiet \
    -project VibeStation5.xcodeproj \
    -scheme VibeStation5 \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Automatic \
    build

app="$derived_data/Build/Products/Release-iphoneos/VibeStation5.app"
if [[ ! -d "$app" ]]; then
    echo "Built app was not found at $app" >&2
    exit 1
fi

staging="$(mktemp -d -t VibeStation5-ipa)"
trap 'rm -rf "$staging"' EXIT

get_task_allow="$(
    codesign -d --entitlements :- "$app" 2>/dev/null |
        plutil -extract get-task-allow raw -o - - 2>/dev/null || true
)"
if [[ "$get_task_allow" != "true" ]]; then
    echo "The signed app is missing get-task-allow and will not appear in StikDebug." >&2
    exit 1
fi

mkdir -p "$staging/Payload" "$(dirname "$output")"
ditto "$app" "$staging/Payload/VibeStation5.app"
(
    cd "$staging"
    /usr/bin/zip -qry "$output" Payload
)

echo "Created SideStore-ready IPA: $output"
echo "The interpreter remains the fallback until StikDebug activates JIT."
