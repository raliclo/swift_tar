#!/usr/bin/env zsh
# Build the bundled static libarchive ZIP backend for macOS.
# 建置 macOS 使用的內附靜態 libarchive ZIP 後端。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

git submodule update --init libarchive

build_dir="build/libarchive-macos"
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

# Record the pinned gitlink, mirroring build_libarchive-win.zsh. Until this was
# added, version-mac.txt carried no libarchive provenance at all and the shared
# version.txt made a macOS build look as if it had linked the library the
# Windows build linked.
# 記錄所固定的 gitlink，與 build_libarchive-win.zsh 相同。在此之前 version-mac.txt
# 完全沒有 libarchive 的來源資訊，而共用的 version.txt 會讓 macOS 建置看起來像是
# 連結了 Windows 建置所連結的那份函式庫。
libarchive_version=$(git -C libarchive describe --tags --always)
libarchive_commit=$(git -C libarchive rev-parse HEAD)
version_file="version-mac.txt"
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
