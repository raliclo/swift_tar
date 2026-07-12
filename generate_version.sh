#!/bin/sh
# Generate the build-time Swift version constant and refresh version.txt.
# 產生建置時 Swift 版本常數，並更新 version.txt。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_swift=${1:?Usage: generate_version.sh <output-swift-file>}
build_version=$(date +%Y%m%d-%H%M%S)

value() {
    key=$1
    if [ -f "$SCRIPT_DIR/version.txt" ]; then
        sed -n "s/^${key}=//p" "$SCRIPT_DIR/version.txt" | sed -n '1p'
    fi
}

zlib_version=$(value zlib_version)
zlib_commit=$(value zlib_commit)
zlib_linkage=$(value zlib_linkage)

{
    echo "swift_tar_version=$build_version"
    [ -n "$zlib_version" ] && echo "zlib_version=$zlib_version"
    [ -n "$zlib_commit" ] && echo "zlib_commit=$zlib_commit"
    [ -n "$zlib_linkage" ] && echo "zlib_linkage=$zlib_linkage"
} > "$SCRIPT_DIR/version.txt.tmp"
mv "$SCRIPT_DIR/version.txt.tmp" "$SCRIPT_DIR/version.txt"

printf 'let swiftTarBuildVersion = "%s"\n' "$build_version" > "$output_swift"
echo "[INFO] swift_tar version: $build_version / swift_tar 版本：$build_version"
