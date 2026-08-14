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

. "$SCRIPT_DIR/platform.sh"
version_file="$SCRIPT_DIR/version-$(swift_tar_platform).txt"

# Refresh the build stamp and keep every other line as the builders left it.
# This used to enumerate the nine zlib/zstd/libarchive keys by name, which meant
# any key a builder added later was silently dropped on the next build — the
# macOS dynamic-linkage records added alongside this change would have vanished
# on the following compile.
# 更新版本戳，其餘各行原樣保留建置腳本寫入的內容。此處原本逐一列舉 zlib／zstd／
# libarchive 那九個鍵，導致建置腳本日後新增的任何鍵，都會在下次建置時被靜默丟棄
# ——與本次一併加入的 macOS 動態連結紀錄，下一次編譯就會消失。
{
    echo "swift_tar_version=$build_version"
    grep -v '^swift_tar_version=' "$version_file" 2>/dev/null || true
} > "$version_file.tmp"
mv "$version_file.tmp" "$version_file"

printf 'let swiftTarBuildVersion = "%s"\n' "$build_version" > "$output_swift"
echo "[INFO] swift_tar version: $build_version / swift_tar 版本：$build_version"
