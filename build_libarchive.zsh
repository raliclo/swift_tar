#!/usr/bin/env zsh
# Build the bundled static libarchive ZIP backend for macOS or Linux.
# 建置 macOS 或 Linux 使用的內附靜態 libarchive ZIP 後端。
#
#   zsh ./build_libarchive.zsh          build it for the detected platform
#                                       依偵測到的平台建置
#   zsh ./build_libarchive.zsh --help   print this synopsis and exit
#                                       印出本說明後結束
set -eu

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,8p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"
. ./platform.zsh

git submodule update --init libarchive

# 套用本樹對 libarchive 的 patch，建置完成後還原，使 submodule 只在編譯期間是「髒」的。
#
# 為什麼要還原：一個長期帶著本地修改的 submodule 會擋住它自己的升級。`sync_all.zsh`
# 刻意跳過有本地修改的 submodule（不覆蓋別人未提交的工作），所以 patch 若一直留在工作區，
# `--update libarchive` 就永遠只會印「跳過」而什麼都不做——升級失敗的樣子和沒事一樣。
# 還原之後，`git status` 乾淨、`sync_all.zsh` 正常運作，而編譯出來的靜態庫仍帶著修正。
#
# 用 trap：建置失敗時也要還原，否則一次失敗的建置會把工作區留在髒狀態，而下一個人不會
# 知道那是 patch 還是自己改的。
#
# 這樣是安全的，因為**每一次**建置都會先套用再還原：不存在「還原後某次增量編譯偷偷用到
# 未修正的原始碼」的空隙。
#
# Apply this tree's libarchive patches, and revert them once the build is done, so the
# submodule is dirty only while compiling.
#
# Why revert: a submodule left permanently modified blocks its own upgrade. `sync_all.zsh`
# skips submodules with local changes on purpose, so a patch parked in the working tree
# makes `--update libarchive` print "skipped" forever and do nothing — a failed upgrade that
# looks exactly like an uneventful one. Reverting leaves `git status` clean and sync_all
# working, while the static library that was just built still carries the fix.
#
# Via a trap, so a failed build reverts too: otherwise one failure leaves the tree dirty and
# the next person cannot tell the patch from their own edit. Safe because every build
# applies first, so there is no window in which an incremental compile quietly uses
# unpatched sources.
if [ -x ./patch/apply_patches.zsh ]; then
    trap './patch/apply_patches.zsh --revert >/dev/null 2>&1 || true' EXIT
    ./patch/apply_patches.zsh
fi

case "$(swift_tar_platform)" in
    mac)   build_dir="build/libarchive-macos"; version_file="version-mac.txt" ;;
    linux) build_dir="build/libarchive-linux"; version_file="version-linux.txt" ;;
    *)
        echo "[FAIL] unsupported platform / 不支援的平台：$(swift_tar_platform)" >&2
        exit 1
        ;;
esac
cmake -S libarchive -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_ZLIB=ON \
    -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_OPENSSL=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF \
    -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DENABLE_BZip2=OFF \
    -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_WIN32_XMLLITE=OFF \
    -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_CNG=OFF \
    -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
    -DENABLE_XATTR=OFF -DENABLE_ACL=OFF -DENABLE_ICONV=OFF \
    -DENABLE_TEST=OFF -DENABLE_INSTALL=OFF
cmake --build "$build_dir" --config Release --target archive_static --parallel

archive_lib="$build_dir/libarchive/libarchive.a"
if [ ! -f "$archive_lib" ]; then
    echo "[FAIL] $archive_lib not found / 找不到 libarchive 靜態庫" >&2
    exit 1
fi

clang -O2 -Ilibarchive/libarchive -c libarchive_zip_bridge.c \
    -o build/libarchive_zip_bridge.o

# Record the pinned gitlink in this platform's provenance file, mirroring
# build_libarchive-win.zsh without letting a Linux build overwrite macOS data.
# 將固定的 gitlink 記錄於本平台的來源資訊檔，與 build_libarchive-win.zsh 相同，
# 且不讓 Linux 建置覆寫 macOS 資料。
libarchive_version=$(git -C libarchive describe --tags --always)
libarchive_commit=$(git -C libarchive rev-parse HEAD)
tmp_version="$version_file.tmp"
{
    grep -vE '^libarchive_(version|commit|linkage)=' "$version_file" 2>/dev/null || true
    echo "libarchive_version=$libarchive_version"
    echo "libarchive_commit=$libarchive_commit"
    echo "libarchive_linkage=static"
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built bundled libarchive ZIP backend / 已建置內附 libarchive ZIP 後端"
echo "[OK] Updated $version_file / 已更新 $version_file"
