#!/usr/bin/env zsh
# build_zstd-win.sh -- sync the pinned zstd submodule and rebuild its Windows
# static library, then record the exact dependency version for packaging.
# build_zstd-win.sh -- 同步固定版本的 zstd submodule、重建 Windows 靜態庫，
# 並記錄封裝所需的精確相依版本。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

git submodule update --init zstd

# A dependency update can change CMake target/output names. This helper is
# intentionally separate from normal builds, so prefer a clean dependency
# rebuild over risking a stale library from the previous gitlink.
# 相依版本更新可能改變 CMake target／輸出名稱。此 helper 本來就與日常建置
# 分離，因此每次乾淨重建，避免誤連前一個 gitlink 留下的舊 library。
#
# zstd keeps its CMake *source* project in zstd/build/cmake, so we must NOT
# delete the whole zstd/build tree to clean it: that removes the source and
# makes the `cmake -S zstd/build/cmake` step below fail with
# "The source directory ... does not exist". Downstream (compile_tar-win.bat)
# also hardcodes zstd/build/lib/Release, so the output must stay under
# zstd/build. Instead, reset zstd/build to its pristine tracked state --
# restore any deleted tracked source, then drop all generated/untracked output.
# zstd 的 CMake 原始碼在 zstd/build/cmake，因此不能整個刪掉 zstd/build 來清理
# （會連原始碼一起刪掉，導致下方 `cmake -S zstd/build/cmake` 找不到來源）。且
# 下游 compile_tar-win.bat 寫死 zstd/build/lib/Release，輸出必須留在 zstd/build。
# 改為把 zstd/build 還原成乾淨的受版控狀態：先還原被刪的受版控原始碼，再清掉產生物。
git -C "$SCRIPT_DIR/zstd" checkout -- build
git -C "$SCRIPT_DIR/zstd" clean -ffdx build

if [ ! -f "$SCRIPT_DIR/zstd/build/cmake/CMakeLists.txt" ]; then
    echo "[FAIL] zstd/build/cmake/CMakeLists.txt missing -- submodule not populated." >&2
    echo "[hint] run: git submodule update --init --force zstd" >&2
    exit 1
fi

# zstd's CMake project lives under build/cmake. Build ONLY the static libzstd
# target -- no CLI programs, tests, legacy formats, or multithreading (we
# compress one zstd frame per chunk with a single in-process ZSTD_compress).
# zstd 的 CMake 專案在 build/cmake。只建靜態 libzstd target——不建 CLI／測試／
# 舊格式／多執行緒（每 chunk 一個 frame，in-process 單次 ZSTD_compress）。
cmake -S zstd/build/cmake -B zstd/build -G "Visual Studio 17 2022" -A x64 \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_LEGACY_SUPPORT=OFF \
    -DZSTD_MULTITHREAD_SUPPORT=OFF
cmake --build zstd/build --config Release --target libzstd_static

# MSVC renames the static lib to zstd_static.lib (avoids clashing with the
# shared import library). / MSVC 會把靜態庫改名為 zstd_static.lib（避免與
# 動態庫的 import library 撞名）。
lib="zstd/build/lib/Release/zstd_static.lib"
if [ ! -f "$lib" ]; then
    echo "[FAIL] $lib not found / 找不到 zstd 靜態庫" >&2
    echo "[hint] .lib files that were built instead / 實際建出的 .lib：" >&2
    find zstd/build -name '*.lib' 2>/dev/null >&2 || true
    exit 1
fi

zstd_version=$(git -C zstd describe --tags --exact-match 2>/dev/null || \
    git -C zstd describe --tags --always)
zstd_commit=$(git -C zstd rev-parse HEAD)

# Preserve every other line in version-win.txt (e.g. swift_tar_version, zlib_*);
# only refresh the zstd_* keys. / 保留 version-win.txt 其他所有行（如
# swift_tar_version、zlib_*），只更新 zstd_* 鍵。
version_file="version-win.txt"
tmp_version="$version_file.tmp"
{
    grep -vE '^zstd_(version|commit|linkage)=' "$version_file" 2>/dev/null || true
    echo "zstd_version=$zstd_version"
    echo "zstd_commit=$zstd_commit"
    echo "zstd_linkage=static"
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built zstd $zstd_version ($zstd_commit) / 已建置 zstd 靜態庫"
echo "[OK] Updated $version_file / 已更新 $version_file"
