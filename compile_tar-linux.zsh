#!/usr/bin/env zsh
# =====================================================================
# compile_tar-linux.zsh — build swift_tar on Linux, as a static musl executable.
# compile_tar-linux.zsh — 在 Linux 上建置 swift_tar，產出靜態的 musl 執行檔。
#
# Since 2026-11-04 every Linux build is musl, by the user's decision: the release was already
# static musl (compile_tar-musl.zsh, built on the Mac), and the dev/test build here linked
# glibc, so the suites on Linux tested a binary nobody shipped. This script is now a thin
# front for `./compile_tar-musl.zsh native`, which builds for this host's architecture with
# the Swift toolchain and the matching Static Linux SDK. The glibc build is gone; it is in git
# history before this change.
# 自 2026-11-04 起，依使用者的決定，所有 Linux 建置都是 musl：正式版本來就是靜態 musl
# （compile_tar-musl.zsh，在 Mac 上建置），而這裡的開發／測試建置連結 glibc，所以 Linux 上的測試
# 測的是一個沒有人出貨的執行檔。本腳本現在是 `./compile_tar-musl.zsh native` 的薄包裝，以 Swift
# toolchain 與相符的 Static Linux SDK 為本機架構建置。glibc 建置已移除，留在本次改動前的 git 歷史裡。
#
# What it keeps from the glibc script / 沿用自 glibc 版的部分：
#   * LZFSE is included when lzfse2/ is checked out, unless EXCLUDE_LZFSE=1, exactly as
#     `./compile_tar.zsh --no-lzfse` on macOS. / lzfse2 已 checkout 時含 LZFSE，除非
#     EXCLUDE_LZFSE=1，與 macOS 的 `./compile_tar.zsh --no-lzfse` 相同。
#   * libarchive and every codec are the bundled static copies from the submodules; asking
#     for the sysroot's (LIBARCHIVE_STATIC=0, CODECS_STATIC=0) is refused, not ignored.
#     libarchive 與各 codec 一律是子模組建出的內附靜態版；要求 sysroot 的版本
#     （LIBARCHIVE_STATIC=0、CODECS_STATIC=0）會被拒絕，不會被忽略。
#   * The buildroot guest's toolchain at /workspace/opt/swift/usr is found first.
#     先找 buildroot guest 在 /workspace/opt/swift/usr 的 toolchain。
#   * The readelf checks: no writable-and-executable LOAD segment, and a readelf that fails
#     stops the build (2026-10-31 review S2). / readelf 檢查：沒有可寫又可執行的 LOAD 區段；
#     readelf 本身失敗即停止（2026-10-31 審查 S2）。
#
# Needs: Swift 6.4.x with its Static Linux SDK installed (`swift sdk install`), cmake.
# 需要：Swift 6.4.x 與已安裝的 Static Linux SDK（`swift sdk install`）、cmake。
#
# Environment / 環境變數:
#   SWIFT_PREFIX      Swift toolchain prefix (contains bin/swiftc, bin/clang, bin/ld.lld)
#   SWIFT_STATIC_SDK  the SDK's swift-linux-musl directory, if not where swiftpm installs it
#   EXCLUDE_LZFSE     1 = public build even where lzfse2 is checked out
#
# Output / 輸出：release/swift_tar, version-linux.txt
#
# Usage / 用法:
#   ./compile_tar-linux.zsh          build for this Linux host / 在此 Linux 主機上建置
#   ./compile_tar-linux.zsh --help   print this synopsis and exit, building nothing
#                                    印出本說明後結束，不進行任何建置
# =====================================================================
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    sed -n '3,44p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi
cd "${script_path:h}"

die() { print -u2 -- "[swift_tar-linux] ERROR / 錯誤：$*"; exit 1; }
log_msg() { print -- "[swift_tar-linux] $*"; }

[[ $(uname -s) == Linux ]] || die "this is the Linux build; on macOS use ./compile_tar.zsh / 這是 Linux 建置"
[[ ${LIBARCHIVE_STATIC:-1} == 1 ]] || die "LIBARCHIVE_STATIC=${LIBARCHIVE_STATIC} 已不支援：libarchive 一律由 libarchive/ 建出 / is no longer supported: libarchive is always built from libarchive/"
[[ ${CODECS_STATIC:-1} == 1 ]] || die "CODECS_STATIC=${CODECS_STATIC} 已不支援：musl 建置一律連結子模組的靜態 codec / is no longer supported: the musl build always links the submodules' static codecs"

if [[ -z ${SWIFT_PREFIX:-} && -x /workspace/opt/swift/usr/bin/swiftc ]]; then
    export SWIFT_PREFIX=/workspace/opt/swift/usr
fi

if [[ -n ${EXCLUDE_LZFSE:-} && ${EXCLUDE_LZFSE} != 0 ]]; then
    log_msg "EXCLUDE_LZFSE 已設定；不含 LZFSE 引擎 / set; building with -DEXCLUDE_LZFSE"
    export SWIFT_TAR_LZFSE=0
elif [[ -f lzfse2/lzfse-cli.swift ]]; then
    log_msg "lzfse2 present; building WITH the LZFSE engine / 含 LZFSE 引擎"
    export SWIFT_TAR_LZFSE=1
else
    log_msg "no lzfse2 checkout; building with -DEXCLUDE_LZFSE / 不含 LZFSE 引擎"
    export SWIFT_TAR_LZFSE=0
fi

zsh ./compile_tar-musl.zsh native

# The S2 checks, kept: a readelf that fails is an error, not a pass.
# 保留 S2 的檢查：readelf 失敗是錯誤，不是通過。
if command -v readelf >/dev/null 2>&1; then
    segs=$(readelf -lW release/swift_tar) || die "readelf -lW 對 release/swift_tar 失敗 / readelf -lW failed on release/swift_tar"
    [[ $segs != *INTERP* ]] || die "release/swift_tar 有 program interpreter，不是靜態執行檔 / has a program interpreter; it is not static"
    if print -r -- "$segs" | grep -E '^ +LOAD ' | grep -q 'RWE'; then
        die "release/swift_tar 有同時可寫又可執行的 LOAD 區段 / has a LOAD segment that is both writable and executable"
    fi
fi

log_msg "Built ./release/swift_tar / 已建置 ./release/swift_tar"
./release/swift_tar --version
