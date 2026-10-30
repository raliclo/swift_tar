#!/usr/bin/env zsh
# build_zstd-win.zsh -- check the zstd submodule is at its pin (checking it out if absent) and
# rebuild its Windows static library, then record the exact dependency version for packaging.
# build_zstd-win.zsh -- 確認 zstd submodule 停在釘選的 commit（未 checkout 則 checkout）、重建
# Windows 靜態庫，並記錄封裝所需的精確相依版本。
#
#   zsh ./build_zstd-win.zsh          clean-rebuild the static libzstd
#                                     乾淨重建靜態 libzstd
#   zsh ./build_zstd-win.zsh --help   print this synopsis and exit
#                                     印出本說明後結束
set -eu

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,10p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

# Never moves a checked-out submodule; see submodule_pins.zsh. / 絕不移動已 checkout 的子模組；見 submodule_pins.zsh。
. ./submodule_pins.zsh
ensure_submodule_pins zstd || exit 1

# A dependency update can change CMake target/output names. This helper is
# intentionally separate from normal builds, so prefer a clean dependency
# rebuild over risking a stale library from the previous gitlink.
# 相依版本更新可能改變 CMake target／輸出名稱。此 helper 本來就與日常建置
# 分離，因此每次乾淨重建，避免誤連前一個 gitlink 留下的舊 library。
#
# zstd keeps its CMake source project in zstd/build/cmake, but the binary tree
# belongs to swift_tar. Keeping it under build/zstd-win leaves the submodule
# untouched, so git status can report every unexpected file there.
# zstd 的 CMake 原始碼位於 zstd/build/cmake，但 binary tree 屬於 swift_tar。
# 將它放在 build/zstd-win 可避免改動 submodule，使 git status 能回報其中所有非預期檔案。
build_dir="$SCRIPT_DIR/build/zstd-win"
rm -rf -- "$build_dir"

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
#
# Compiler: the Swift toolchain's clang (GNU driver, MSVC ABI), not MSVC cl.exe. Measured by
# verifications/zstd_bmi2_win.zsh on claw-code (variant e there). Note what this does NOT buy:
# zstd's run-time BMI2 dispatch stays inert, because compiler.h defines TARGET_ATTRIBUTE only under
# __GNUC__, which clang does not define when targeting MSVC -- the gain is clang's codegen.
# The generator (NMake, not Visual Studio) and the paths come from win_clang_cmake.zsh.
# -ffunction-sections/-fdata-sections are clang's counterpart of the /Gy that MSVC's /O2 implies: one
# section per function, so the linker can drop what swift_tar never calls. Measured 2026-10-30 on
# swift_tar.exe (MSVC zstd: 1,619,456 bytes): clang without them 1,808,384, with them 1,756,160. The
# remaining +136,704 (all .text) is clang -O3's inlining and unrolling, not dead code: the level is
# chosen at run time, so every zstd strategy is reachable and the linker can drop none of them.
# 編譯器：Swift 工具鏈的 clang（GNU 驅動、MSVC ABI），而非 MSVC cl.exe。由
# verifications/zstd_bmi2_win.zsh 在 claw-code 上量測（該處的 e 版本）。注意它「沒有」帶來的：zstd 的
# 執行時 BMI2 分派仍不生效，因為 compiler.h 只在 __GNUC__ 下定義 TARGET_ATTRIBUTE，而 clang 以 MSVC
# 為目標時不定義它——收益來自 clang 的程式碼生成。產生器（NMake，而非 Visual Studio）與路徑來自
# win_clang_cmake.zsh。
# -ffunction-sections／-fdata-sections 對應 MSVC /O2 隱含的 /Gy：每個函式一個 section，連結器才能丟掉
# swift_tar 用不到的部分。2026-10-30 量測 swift_tar.exe（MSVC 版 zstd 為 1,619,456 位元組）：clang 不加
# 為 1,808,384，加上後為 1,756,160。剩下的 +136,704（全在 .text）是 clang -O3 的 inline 與展開，不是
# 死碼：壓縮等級在執行時才決定，所有 zstd 策略都可能被呼叫，連結器一個也丟不掉。
. ./win_clang_cmake.zsh
win_clang_cmake clang "$build_dir/lib/Release" || exit 1
cmake -S zstd/build/cmake -B "$build_dir" "${win_cmake_args[@]}" \
    -DCMAKE_CXX_COMPILER="$win_cc" \
    -DCMAKE_ASM_COMPILER="$win_cc" \
    "-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections" \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_LEGACY_SUPPORT=OFF \
    -DZSTD_MULTITHREAD_SUPPORT=OFF
cmake --build "$build_dir" --target libzstd_static

# zstd's CMake names the static lib zstd_static.lib for MSVC and for clang targeting
# MSVC alike (avoids clashing with the shared import library). / zstd 的 CMake 對 MSVC
# 與以 MSVC 為目標的 clang 都把靜態庫命名為 zstd_static.lib（避免與動態庫的 import
# library 撞名）。
lib="$build_dir/lib/Release/zstd_static.lib"
if [ ! -f "$lib" ]; then
    echo "[FAIL] $lib not found / 找不到 zstd 靜態庫" >&2
    echo "[hint] .lib files that were built instead / 實際建出的 .lib：" >&2
    find "$build_dir" -name '*.lib' 2>/dev/null >&2 || true
    exit 1
fi

zstd_version=$(git -C zstd describe --tags --exact-match 2>/dev/null || \
    git -C zstd describe --tags --always)
zstd_commit=$(git -C zstd rev-parse HEAD)

# Preserve every other line in version-win.txt (e.g. swift_tar_version, zlib_*);
# only refresh the zstd_* keys. / 保留 version-win.txt 其他所有行（如
# swift_tar_version、zlib_*），只更新 zstd_* 鍵。
version_file="version-win.txt"
# grep's status 1 (nothing printed) is the only one tolerated; see build_zlib-win.zsh.
# Was `2>/dev/null || true`, which also swallowed a real error (2026-09-27).
# 僅容忍 grep 的狀態 1（沒有輸出），理由見 build_zlib-win.zsh。原本是
# `2>/dev/null || true`，連真正的錯誤也一併吞掉（2026-09-27）。
[ -f "$version_file" ] || { echo "[FAIL] $version_file missing / 找不到 $version_file" >&2; exit 1; }
tmp_version="$version_file.tmp"
{
    grep -vE '^zstd_(version|commit|linkage)=' "$version_file" || [ $? -eq 1 ]
    echo "zstd_version=$zstd_version"
    echo "zstd_commit=$zstd_commit"
    echo "zstd_linkage=static"
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built zstd $zstd_version ($zstd_commit) / 已建置 zstd 靜態庫"
echo "[OK] Updated $version_file / 已更新 $version_file"
