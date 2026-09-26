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
# Keep every other line and refresh only the zlib_* keys, the same way
# build_zstd-win.zsh and build_libarchive-win.zsh do. This used to rebuild the file
# from a whitelist -- swift_tar_version plus `(zstd|libarchive)_*` -- so any key another
# builder added later was dropped without a word (2026-09-27 review; decided that day
# that all builders follow one pattern).
#
# grep exits 1 when it prints nothing, which here means the file held only zlib keys;
# that one status is tolerated. A missing file is refused first, so a real grep error
# (2) still fails the build instead of producing a truncated record.
#
# 保留其他所有行，只更新 zlib_* 鍵，與 build_zstd-win.zsh、build_libarchive-win.zsh 的
# 作法相同。這裡原本是以白名單重建整個檔案——swift_tar_version 加上 `(zstd|libarchive)_*`
# ——所以其他建置腳本日後新增的鍵都會被無聲丟棄（2026-09-27 審查；當日決定所有建置腳本
# 採同一種寫法）。
#
# grep 沒有輸出時以 1 結束，在此即代表檔案裡只有 zlib 鍵；僅容忍該狀態。檔案不存在會先被
# 拒絕，所以真正的 grep 錯誤（2）仍會讓建置失敗，而不是產生一份被截斷的紀錄。
[ -f "$version_file" ] || { echo "[FAIL] $version_file missing / 找不到 $version_file" >&2; exit 1; }
tmp_version="$version_file.tmp"
{
    grep -vE '^zlib_(version|commit|linkage)=' "$version_file" || [ $? -eq 1 ]
    echo "zlib_version=$zlib_version"
    echo "zlib_commit=$zlib_commit"
    echo "zlib_linkage=static"
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built zlib $zlib_version ($zlib_commit) / 已建置 zlib 靜態庫"
echo "[OK] Updated $version_file / 已更新 $version_file"
