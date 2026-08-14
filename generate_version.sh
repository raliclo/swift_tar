#!/usr/bin/env zsh
# Generate the build-time Swift version constant and refresh version-<plat>.txt.
# 產生建置時 Swift 版本常數，並更新 version-<平台>.txt。
#
# One file per platform. A shared version.txt meant a macOS build overwrote the
# stamp and the linkage provenance recorded by the Windows build scripts, and
# vice versa — the two describe different binaries linked against differently
# built libraries, so they were never the same fact to begin with.
# 每個平台一個檔案。共用 version.txt 會使 macOS 建置覆寫 Windows 建置腳本所記錄的
# 版本戳與連結來源，反之亦然——兩者描述的是連結到不同建置產物的不同執行檔，本來就
# 不是同一件事實。
set -eu

SCRIPT_DIR=${SWIFT_TAR_SOURCE_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
output_swift=${1:?Usage: generate_version.sh <output-swift-file>}
build_version=$(date +%Y%m%d-%H%M%S)

case "$(uname -s)" in
    Darwin)               platform=mac ;;
    Linux)                platform=linux ;;
    MINGW*|MSYS*|CYGWIN*) platform=win ;;
    *)                    platform=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac
version_file="$SCRIPT_DIR/version-$platform.txt"

value() {
    key=$1
    if [ -f "$version_file" ]; then
        sed -n "s/^${key}=//p" "$version_file" | sed -n '1p'
    fi
}

zlib_version=$(value zlib_version)
zlib_commit=$(value zlib_commit)
zlib_linkage=$(value zlib_linkage)
zstd_version=$(value zstd_version)
zstd_commit=$(value zstd_commit)
zstd_linkage=$(value zstd_linkage)
libarchive_version=$(value libarchive_version)
libarchive_commit=$(value libarchive_commit)
libarchive_linkage=$(value libarchive_linkage)

{
    echo "swift_tar_version=$build_version"
    [ -n "$zlib_version" ] && echo "zlib_version=$zlib_version"
    [ -n "$zlib_commit" ] && echo "zlib_commit=$zlib_commit"
    [ -n "$zlib_linkage" ] && echo "zlib_linkage=$zlib_linkage"
    [ -n "$zstd_version" ] && echo "zstd_version=$zstd_version"
    [ -n "$zstd_commit" ] && echo "zstd_commit=$zstd_commit"
    [ -n "$zstd_linkage" ] && echo "zstd_linkage=$zstd_linkage"
    [ -n "$libarchive_version" ] && echo "libarchive_version=$libarchive_version"
    [ -n "$libarchive_commit" ] && echo "libarchive_commit=$libarchive_commit"
    [ -n "$libarchive_linkage" ] && echo "libarchive_linkage=$libarchive_linkage"
} > "$version_file.tmp"
mv "$version_file.tmp" "$version_file"

printf 'let swiftTarBuildVersion = "%s"\n' "$build_version" > "$output_swift"
echo "[INFO] swift_tar version: $build_version / swift_tar 版本：$build_version"
