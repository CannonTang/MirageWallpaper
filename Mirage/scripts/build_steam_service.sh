#!/bin/bash
#
#  Mirage Wallpaper
#
#  Copyright © 2026 王孝慈. All rights reserved.
#

set -euo pipefail

APP="${1:?Usage: build_steam_service.sh <Mirage.app> [root] [architectures]}"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ARCHITECTURES="${3:-$(uname -m)}"
SIGN_IDENTITY="${4:-}"
PROJECT="$ROOT/SteamService/MirageSteamService.csproj"
OUTPUT="$ROOT/Mirage/build/SteamService"
DESTINATION="$APP/Contents/Resources/SteamService"

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/Licenses"

publish_architecture() {
    local architecture="$1"
    local runtime="$2"
    local architecture_destination="$DESTINATION/$architecture"
    local restore_options=()
    if [ "${CI:-}" = "true" ]; then
        restore_options=(-p:RestoreLockedMode=true)
    fi
    env -u ASSEMBLY_NAME -u PRODUCT_NAME -u PROJECT_NAME -u TARGET_NAME \
        -u TARGETNAME -u EXECUTABLE_NAME -u FULL_PRODUCT_NAME -u WRAPPER_NAME \
        dotnet publish "$PROJECT" -c Release -f net10.0 -r "$runtime" \
        --self-contained true \
        -p:AssemblyName=MirageSteamService \
        -p:TargetName=MirageSteamService \
        -p:PublishSingleFile=false \
        -p:PublishTrimmed=false \
        -p:DebugType=None \
        -p:DebugSymbols=false \
        "${restore_options[@]}" \
        -o "$OUTPUT/$runtime"
    mkdir -p "$architecture_destination"
    cp -R "$OUTPUT/$runtime/." "$architecture_destination/"
    chmod +x "$architecture_destination/MirageSteamService"
}

published=0
for architecture in $ARCHITECTURES; do
    case "$architecture" in
        arm64)
            publish_architecture arm64 osx-arm64
            published=1
            ;;
        x86_64)
            publish_architecture x86_64 osx-x64
            published=1
            ;;
        *)
            echo "[steam-service] Unsupported architecture: $architecture" >&2
            exit 1
            ;;
    esac
done

if [ "$published" -ne 1 ]; then
    echo "[steam-service] No supported architecture was provided" >&2
    exit 1
fi

cp -f "$ROOT/SteamService/Licenses/LGPL-2.1.txt" "$DESTINATION/Licenses/LGPL-2.1.txt"
cp -f "$ROOT/SteamService/Licenses/SteamKit2-NOTICE.txt" "$DESTINATION/Licenses/SteamKit2-NOTICE.txt"
cp -f "$ROOT/SteamService/Licenses/DepotDownloader-NOTICE.txt" "$DESTINATION/Licenses/DepotDownloader-NOTICE.txt"

if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    while IFS= read -r item; do
        if file "$item" | grep -q 'Mach-O'; then
            codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$item"
        fi
    done < <(find "$DESTINATION" -type f)
fi
