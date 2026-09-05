#!/usr/bin/env zsh
# build_zlib-win.zsh -- sync the pinned zlib submodule and rebuild its Windows
# static library, then record the exact dependency version for packaging.
# build_zlib-win.zsh -- 同步固定版本的 zlib submodule、重建 Windows 靜態庫，
# 並記錄封裝所需的精確相依版本。
#
#   zsh ./build_zlib-win.zsh          clean-rebuild the static zlib
#                                     乾淨重建靜態 zlib
#   zsh ./build_zlib-win.zsh --help   print this synopsis and exit
#                                     印出本說明後結束
set -eu

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,10p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

git submodule update --init zlib

# A dependency update can change CMake target/output names. This helper is
# intentionally separate from normal builds, so prefer a clean dependency
# rebuild over risking a stale library from the previous gitlink.
# 相依版本更新可能改變 CMake target／輸出名稱。此 helper 本來就與日常建置
# 分離，因此每次乾淨重建，避免誤連前一個 gitlink 留下的舊 library。
build_dir="$SCRIPT_DIR/zlib/build"
case "$build_dir" in
    "$SCRIPT_DIR/zlib/build") cmake -E remove_directory "$build_dir" ;;
    *) echo "[FAIL] unsafe zlib build path: $build_dir" >&2; exit 1 ;;
esac

cmake -S zlib -B zlib/build -G "Visual Studio 17 2022" -A x64 \
    -DZLIB_BUILD_SHARED=OFF \
    -DZLIB_BUILD_STATIC=ON \
    -DZLIB_BUILD_TESTING=OFF \
    -DZLIB_INSTALL=OFF
cmake --build zlib/build --config Release --target zlibstatic

if [ ! -f zlib/build/Release/zs.lib ]; then
    echo "[FAIL] zlib/build/Release/zs.lib not found / 找不到 zlib 靜態庫" >&2
    exit 1
fi

zlib_version=$(git -C zlib describe --tags --exact-match 2>/dev/null || \
    git -C zlib describe --tags --always)
zlib_commit=$(git -C zlib rev-parse HEAD)
# These builders only ever run on Windows, so the target file is fixed rather
# than detected. / 這些建置腳本僅在 Windows 上執行，故目標檔案直接寫死而非偵測。
version_file="version-win.txt"
swift_tar_version=$(sed -n 's/^swift_tar_version=//p' "$version_file" 2>/dev/null | sed -n '1p')
tmp_version="$version_file.tmp"
{
    [ -n "$swift_tar_version" ] && echo "swift_tar_version=$swift_tar_version"
    echo "zlib_version=$zlib_version"
    echo "zlib_commit=$zlib_commit"
    echo "zlib_linkage=static"
    # Preserve dependency provenance written by the other backend builders.
    # 保留其他後端建置腳本寫入的相依套件 provenance。
    grep -E '^(zstd|libarchive)_(version|commit|linkage)=' "$version_file" 2>/dev/null || true
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built zlib $zlib_version ($zlib_commit) / 已建置 zlib 靜態庫"
echo "[OK] Updated $version_file / 已更新 $version_file"
