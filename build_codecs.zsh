#!/usr/bin/env zsh
# build_codecs.zsh -- build liblzma (xz), liblz4 and libzstd from their pinned
# submodules as static libraries, and record the gitlinks in version-mac.txt.
# build_codecs.zsh -- 以固定版本的 submodule 建置 liblzma(xz)、liblz4 與 libzstd
# 靜態庫，並將 gitlink 記入 version-mac.txt。
#
#   zsh ./build_codecs.zsh          build all three / 建置三者
#   zsh ./build_codecs.zsh --help   print this synopsis and exit / 印出說明後結束
#
# Why this exists / 為什麼有這支腳本
#
#   b6d26c7 vendored xz and lz4 as submodules, alongside zstd, and explained why
#   at length -- but it added only the pins. Nothing built them, `git submodule
#   status` showed both uninitialised, and compile_tar.zsh went on linking
#   /opt/homebrew. So the version of liblzma inside a release binary was whatever
#   `brew upgrade` had last installed. That is not hypothetical: xz moved from
#   14.3.0 to 14.4.0 with no commit asking for it, and the only trace was
#   version-mac.txt changing under a build nobody had requested a codec change from.
#
#   b6d26c7 將 xz 與 lz4 與 zstd 並列加為 submodule，理由寫得很完整——但它只加了 pin。
#   沒有任何東西建置它們，`git submodule status` 顯示兩者從未 init，而 compile_tar.zsh
#   仍繼續連結 /opt/homebrew。於是發行執行檔裡的 liblzma 版本，等於 `brew upgrade` 最後
#   裝上的那一份。這不是假設：xz 由 14.3.0 變成 14.4.0，沒有任何 commit 要求它，唯一的
#   痕跡是 version-mac.txt 在一次沒人要求更動 codec 的建置中被改寫。
#
# Static, not shared / 靜態而非動態
#
#   Static is the point. A dynamic /opt/homebrew/opt/xz/... dylib makes the
#   recorded version describe the build machine rather than the tree, and the
#   path itself is wrong on any Mac without homebrew at that prefix. The cost is
#   real and worth stating: a liblzma CVE fix no longer arrives via `brew
#   upgrade`; it needs this script re-run and the binary re-released.
#
#   靜態正是目的。動態連結 /opt/homebrew/opt/xz/... 會讓紀錄中的版本描述的是「這台建置
#   機器」而非這棵樹，且該路徑在任何沒有把 homebrew 裝在該前綴的 Mac 上都是錯的。代價
#   是真實的，必須講明：liblzma 的 CVE 修補不再由 `brew upgrade` 帶進來，而需要重跑本
#   腳本並重新發行執行檔。
#
# No headers are needed / 不需要標頭檔
#
#   swift_tar reaches all three through @_silgen_name, declaring the C entry
#   points in Swift, so the switch is a linker change only -- no module map, no
#   include path. That is why this script produces .a files and nothing else.
#   swift_tar 以 @_silgen_name 直接在 Swift 宣告三者的 C 進入點，故此次更動僅涉及連結器
#   ——沒有 module map，也沒有 include 路徑。這就是本腳本只產出 .a 的原因。
set -eu

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,8p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"
. ./platform.zsh

# macOS only. Linux links the distribution's liblzma/liblz4/libzstd from the
# sysroot (compile_tar-linux.zsh) and Windows shells out to scoop CLIs; neither
# is changed by this script.
# 僅限 macOS。Linux 連結發行版 sysroot 內的 liblzma／liblz4／libzstd
# （compile_tar-linux.zsh），Windows 則呼叫 scoop 安裝的 CLI；兩者皆不受本腳本影響。
if [ "$(swift_tar_platform)" != "mac" ]; then
    echo "[FAIL] build_codecs.zsh is macOS-only / 本腳本僅適用於 macOS：$(swift_tar_platform)" >&2
    exit 1
fi

version_file="version-mac.txt"

# Not a clean rebuild. cmake is incremental, and this runs on every
# compile_tar.zsh; a clean rebuild of three libraries per compile would be minutes
# of rebuilding identical bytes. build_libarchive.zsh takes the same position.
# 不做乾淨重建。cmake 是增量的，而本腳本每次 compile_tar.zsh 都會執行；每次編譯都把三個
# 函式庫重建一遍，等於花數分鐘重建完全相同的位元組。build_libarchive.zsh 亦採同一立場。

git submodule update --init xz lz4 zstd

# ---- xz / liblzma ----
# The encoder is needed as well as the decoder: swift_tar calls
# lzma_easy_buffer_encode. The lzip decoder stays on, because lzma_lzip_decoder
# is one of the declared entry points -- `.lz` support would disappear silently
# without it, since @_silgen_name resolves at link time, not at compile time.
# 編碼器與解碼器都需要：swift_tar 會呼叫 lzma_easy_buffer_encode。lzip 解碼器維持開啟，
# 因為 lzma_lzip_decoder 是已宣告的進入點之一——若關掉，`.lz` 支援會靜默消失，因為
# @_silgen_name 是在連結期而非編譯期解析。
cmake -S xz -B build/xz-macos \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DXZ_NLS=OFF -DXZ_DOC=OFF \
    -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF \
    -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF
cmake --build build/xz-macos --config Release --target liblzma --parallel

# ---- lz4 ----
cmake -S lz4/build/cmake -B build/lz4-macos \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF
cmake --build build/lz4-macos --config Release --target lz4_static --parallel

# ---- zstd ----
# The same option set build_zstd-win.zsh uses, deliberately: swift_tar compresses
# one frame per chunk with a single in-process ZSTD_compress, so no CLI, no tests
# and no multithreading.
#
# ZSTD_LEGACY_SUPPORT=OFF is a behaviour change on macOS and is the one thing here
# worth knowing about. Homebrew's libzstd is built with legacy support ON, so until
# now the macOS binary could decode zstd frames in the pre-v0.8 formats and the
# Windows binary could not. Matching Windows removes that asymmetry -- an archive
# that one platform of this tree reads and another rejects is worse than neither
# reading a format that upstream stopped producing in 2016.
#
# 這組選項刻意與 build_zstd-win.zsh 相同：swift_tar 每個 chunk 以單次 in-process
# ZSTD_compress 壓成一個 frame，故不需 CLI、測試與多執行緒。
#
# ZSTD_LEGACY_SUPPORT=OFF 是 macOS 上的行為改變，也是此處唯一值得知道的一點。homebrew
# 的 libzstd 帶有 legacy 支援，因此在此之前 macOS 版能解 v0.8 之前的舊格式 frame，而
# Windows 版不能。與 Windows 一致可消除這個不對稱——同一棵樹的一個平台讀得到、另一個
# 拒收，比兩者都不支援一個上游自 2016 年起就不再產生的格式更糟。
cmake -S zstd/build/cmake -B build/zstd-macos \
    -DCMAKE_BUILD_TYPE=Release \
    -DZSTD_BUILD_STATIC=ON \
    -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_LEGACY_SUPPORT=OFF \
    -DZSTD_MULTITHREAD_SUPPORT=OFF
cmake --build build/zstd-macos --config Release --target libzstd_static --parallel

# ---- check the artefacts exist, and say which ones did not ----
# 檢查產物是否存在，並指出沒有產出的是哪一個
lib_xz="build/xz-macos/liblzma.a"
lib_lz4="build/lz4-macos/liblz4.a"
lib_zstd="build/zstd-macos/lib/libzstd.a"
#
# `lib_path`, not `path`. In zsh `path` is tied to `PATH`, so assigning a filename
# to it replaces the command search path with that one string -- every later `git`,
# `grep` and `mv` in this script then fails with "command not found", hundreds of
# lines after the build they were meant to record. Caught here the first time this
# script ran.
# 用 `lib_path` 而非 `path`。zsh 的 `path` 與 `PATH` 綁定，把檔名指派給它會使命令搜尋路徑
# 變成那一個字串——本腳本後續每一個 `git`、`grep` 與 `mv` 都會以「command not found」失敗，
# 且發生在它們所要記錄的建置之後數百行處。本腳本首次執行時即踩到。
missing=0
for pair in "xz:$lib_xz" "lz4:$lib_lz4" "zstd:$lib_zstd"; do
    name="${pair%%:*}"; lib_path="${pair#*:}"
    if [ ! -f "$lib_path" ]; then
        echo "[FAIL] $name: $lib_path not found / 找不到靜態庫" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "[hint] .a files that were built instead / 實際建出的 .a：" >&2
    find build/xz-macos build/lz4-macos build/zstd-macos -name '*.a' >&2 || true
    exit 1
fi

# ---- record the gitlinks / 記錄 gitlink ----
# The identifying fact for a static library is the commit it was built from, not
# a dylib "current version" read back with otool -- there is no dylib to read.
# This also clears the stale *_dylib_version / *_path keys the homebrew era left
# behind, which would otherwise sit in the file describing a library the binary
# no longer loads.
# 靜態庫的識別事實是它由哪個 commit 建出，而非以 otool 讀回的 dylib「current version」
# ——已經沒有 dylib 可讀。此處同時清掉 homebrew 時期遺留的 *_dylib_version 與 *_path
# 鍵，否則它們會留在檔案裡，描述一個執行檔已不再載入的函式庫。
describe() {             # submodule dir / submodule 目錄
    git -C "$1" describe --tags --exact-match 2>/dev/null || \
        git -C "$1" describe --tags --always
}
if [ ! -f "$version_file" ]; then
    echo "[FAIL] $version_file missing / 找不到 $version_file" >&2
    exit 1
fi
tmp_version="$version_file.tmp"
{
    # grep exits 1 when it prints nothing, which here would mean the file held
    # nothing but codec keys. Tolerated for that one status; a real grep error (2)
    # still fails, and a missing file is already refused above, so this cannot
    # quietly produce a truncated record.
    # grep 在沒有輸出時以 1 結束，在此情境即代表檔案裡只有 codec 鍵。僅容忍該狀態；
    # 真正的 grep 錯誤（2）仍會失敗，而檔案不存在已於上方擋下，故此處不會靜默產生
    # 一份被截斷的紀錄。
    grep -vE '^(lz4|xz|zstd)_(dylib_version|path|version|commit|linkage)=' \
        "$version_file" || [ $? -eq 1 ]
    for pair in "lz4:lz4" "xz:xz" "zstd:zstd"; do
        key="${pair%%:*}"; dir="${pair#*:}"
        echo "${key}_version=$(describe "$dir")"
        echo "${key}_commit=$(git -C "$dir" rev-parse HEAD)"
        echo "${key}_linkage=static"
    done
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built static liblzma, liblz4 and libzstd / 已建置靜態 liblzma、liblz4 與 libzstd"
echo "[OK] Updated $version_file / 已更新 $version_file"
