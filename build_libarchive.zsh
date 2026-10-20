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

# A source drop has no .git and may land where there is no git at all (the Buildroot
# guest). There the sources are whatever was shipped: this script cannot fetch the pin,
# and says so. The patches are still applied -- apply_patches.zsh works without git --
# because an unpatched libarchive builds and links exactly like a patched one.
# 原始碼包沒有 .git，也可能落在完全沒有 git 的地方（Buildroot guest）。那裡的原始碼就是送
# 進來的那一份：本腳本取不到 pin，並會明說。patch 仍然會套用——apply_patches.zsh 不需要
# git——因為未 patch 的 libarchive 建置與連結起來和 patch 過的一模一樣。
in_git=0
if command -v git >/dev/null 2>&1 && [ -e .git ]; then in_git=1; fi
if [ "$in_git" = 1 ]; then
    # Never moves a checked-out submodule; see submodule_pins.zsh. / 絕不移動已 checkout 的子模組；見 submodule_pins.zsh。
    . ./submodule_pins.zsh
    ensure_submodule_pins libarchive || exit 1
elif [ -f libarchive/CMakeLists.txt ]; then
    echo "[NOTICE] not a git checkout: building libarchive/ as shipped, at whatever commit that is" >&2
    echo "[注意] 不是 git checkout：依送來的 libarchive/ 原樣建置，不論它是哪個 commit" >&2
else
    echo "[FAIL] no git checkout and no libarchive/ sources / 既非 git checkout，也沒有 libarchive/ 原始碼" >&2
    exit 1
fi

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
#
# A failed revert is loud and fails the build. This trap used to be
# `--revert >/dev/null 2>&1 || true`, so a revert that failed left the submodule dirty
# while the build reported success -- and then sync_all.zsh --update libarchive printed
# "skipped: local changes" forever, the exact outcome described above, with nothing on
# screen to say why (2026-09-27 review). The output is kept only for the failure case:
# a successful revert is routine and says nothing worth reading. A build that had
# already failed keeps its own status rather than being replaced by 1.
#
# 還原失敗時要大聲說，並讓建置失敗。這個 trap 原本是 `--revert >/dev/null 2>&1 || true`，
# 所以還原失敗會讓 submodule 留在髒狀態，建置卻回報成功——接著 sync_all.zsh --update
# libarchive 就永遠印「跳過：有本地修改」，正是上方描述的結局，而畫面上沒有任何東西說明
# 原因（2026-09-27 審查）。輸出只在失敗時保留：成功的還原是例行公事，沒有值得讀的內容。
# 若建置本身已經失敗，保留它自己的退出碼，而不是換成 1。
revert_patches() {
    local st=$? out
    if ! out=$(./patch/apply_patches.zsh --revert 2>&1); then
        print -ru2 -- "[FAIL] patch revert failed; libarchive/ is left modified / patch 還原失敗，libarchive/ 仍留有修改："
        print -ru2 -- "$out"
        print -ru2 -- "       sync_all.zsh --update libarchive will skip it until this is fixed / 修好之前 sync_all.zsh --update libarchive 會一直跳過它"
        (( st == 0 )) && st=1
    fi
    exit $st
}
if [ -x ./patch/apply_patches.zsh ]; then
    # In a source drop there is no upgrade for a dirty tree to block, so the patches
    # stay applied; only a git checkout is reverted. A patch that will not apply stops
    # the build either way (set -e).
    # 原始碼包沒有會被髒工作區擋住的升級，所以 patch 留著不還原；只有 git checkout 才還原。
    # patch 套不上時，兩種情況都會讓建置停下（set -e）。
    [ "$in_git" = 1 ] && trap revert_patches EXIT
    ./patch/apply_patches.zsh
fi

# Linux links swift_tar as a PIE, so the static library must be position-independent;
# without this the link fails on the first relocation. macOS objects always are.
# Linux 以 PIE 連結 swift_tar，靜態庫必須是位置無關碼；否則連結會在第一個重定位失敗。
# macOS 的目的檔一律如此。
platform_flags=()
case "$(swift_tar_platform)" in
    mac)   build_dir="build/libarchive-macos"; version_file="version-mac.txt" ;;
    linux) build_dir="build/libarchive-linux"; version_file="version-linux.txt"
           platform_flags=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON) ;;
    # The musl cross targets (compile_tar-musl.zsh) take their cmake toolchain file from
    # SWIFT_TAR_CMAKE_TOOLCHAIN. / musl 交叉目標（compile_tar-musl.zsh）的 cmake toolchain 檔由
    # SWIFT_TAR_CMAKE_TOOLCHAIN 傳入。
    musl-aarch64|musl-x86_64)
           build_dir="build/libarchive-$(swift_tar_platform)"; version_file="version-$(swift_tar_platform).txt"
           platform_flags=(-DCMAKE_TOOLCHAIN_FILE="${SWIFT_TAR_CMAKE_TOOLCHAIN:?a musl target needs SWIFT_TAR_CMAKE_TOOLCHAIN}") ;;
    *)
        echo "[FAIL] unsupported platform / 不支援的平台：$(swift_tar_platform)" >&2
        exit 1
        ;;
esac
typeset -a zlib_options
zlib_options=()
if [[ -n ${ZLIB_LIBRARY:-} ]]; then
    zlib_options=(-DZLIB_LIBRARY="$ZLIB_LIBRARY" -DZLIB_LIBRARY_RELEASE="$ZLIB_LIBRARY" \
                  -DZLIB_INCLUDE_DIR="${ZLIB_INCLUDE_DIR:?}")
fi
cmake -S libarchive -B "$build_dir" "${zlib_options[@]}" \
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
    -DENABLE_TEST=OFF -DENABLE_INSTALL=OFF \
    "${platform_flags[@]}"

# ENABLE_ZLIB=ON is a request, not a guarantee: when cmake finds no zlib it configures
# without one and the build succeeds, producing a ZIP backend that can only store.
# ENABLE_ZLIB=ON 是請求而非保證：cmake 找不到 zlib 時會照樣完成設定、建置也成功，產出一個
# 只能 store 的 ZIP 後端。
if ! grep -q '^#define HAVE_ZLIB_H 1' "$build_dir/config.h"; then
    echo "[FAIL] cmake configured libarchive without zlib; set ZLIB_LIBRARY and ZLIB_INCLUDE_DIR / cmake 設定出的 libarchive 不含 zlib，請設定 ZLIB_LIBRARY 與 ZLIB_INCLUDE_DIR" >&2
    exit 1
fi
cmake --build "$build_dir" --config Release --target archive_static --parallel

archive_lib="$build_dir/libarchive/libarchive.a"
if [ ! -f "$archive_lib" ]; then
    echo "[FAIL] $archive_lib not found / 找不到 libarchive 靜態庫" >&2
    exit 1
fi

# SWIFT_TAR_ZIP_PARALLEL: the library just built carries patch/libarchive/0003, which is
# what the bridge's threaded compression writes through. The bridge deflates with zlib
# itself there, so it needs the header of the same zlib libarchive was configured with.
# SWIFT_TAR_ZIP_PARALLEL：剛建好的函式庫帶有 patch/libarchive/0003，bridge 的多執行緒壓縮就是
# 經由它寫出。bridge 在那條路徑上自己用 zlib 做 deflate，所以需要 libarchive 設定時所用的
# 同一份 zlib 的 header。
typeset -a bridge_zlib
bridge_zlib=()
[[ -n ${ZLIB_INCLUDE_DIR:-} ]] && bridge_zlib=(-I"$ZLIB_INCLUDE_DIR")
# The compiler the caller named, as cmake above was given it: compile_tar-linux.zsh passes
# CC because clang may exist only under the Swift toolchain and not on PATH.
# 用呼叫端指定的編譯器，與上面的 cmake 一致：compile_tar-linux.zsh 之所以傳入 CC，是因為 clang
# 可能只存在於 Swift toolchain 之下，而不在 PATH 上。
# A musl cross target writes its own object: a shared name would leave a Linux object where
# the next macOS build links build/libarchive_zip_bridge.o.
# musl 交叉目標寫出自己的目的檔：共用同一個名字，下一次 macOS 建置連結
# build/libarchive_zip_bridge.o 時就會拿到 Linux 的目的檔。
bridge_obj=build/libarchive_zip_bridge.o
[[ $(swift_tar_platform) == musl-* ]] && bridge_obj=build/libarchive_zip_bridge-$(swift_tar_platform).o
"${CC:-clang}" -O2 -DSWIFT_TAR_ZIP_PARALLEL -Ilibarchive/libarchive "${bridge_zlib[@]}" \
    -c libarchive_zip_bridge.c -o "$bridge_obj"

# Record the pinned gitlink in this platform's provenance file, mirroring
# build_libarchive-win.zsh without letting a Linux build overwrite macOS data.
# 將固定的 gitlink 記錄於本平台的來源資訊檔，與 build_libarchive-win.zsh 相同，
# 且不讓 Linux 建置覆寫 macOS 資料。
if [ "$in_git" = 1 ]; then
    libarchive_version=$(git -C libarchive describe --tags --always)
    libarchive_commit=$(git -C libarchive rev-parse HEAD)
else
    # No git to ask; say so rather than leave the previous build's values in place.
    # 沒有 git 可問；明說，而不是把上一次建置的值留在原處。
    libarchive_version=unknown-source-drop
    libarchive_commit=unknown
fi
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
