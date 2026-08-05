#!/bin/sh
# Build the bundled static libarchive ZIP backend with MSVC for Windows.
# 使用 MSVC 建置 Windows 使用的內附靜態 libarchive ZIP 後端。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

git submodule update --init libarchive zlib

if [ ! -f zlib/build/Release/zs.lib ]; then
    echo "[FAIL] zlib/build/Release/zs.lib not found; run zsh ./build_zlib-win.sh" >&2
    exit 1
fi

build_dir="build/libarchive-win"
cmake -S libarchive -B "$build_dir" -G "Visual Studio 17 2022" -A x64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DMSVC_USE_STATIC_CRT=OFF \
    -DCMAKE_C_FLAGS=//utf-8 \
    -DZLIB_LIBRARY="$SCRIPT_DIR/zlib/build/Release/zs.lib" \
    -DZLIB_INCLUDE_DIR="$SCRIPT_DIR/zlib" \
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

archive_lib="$build_dir/libarchive/Release/archive.lib"
if [ ! -f "$archive_lib" ]; then
    echo "[FAIL] $archive_lib not found / 找不到 libarchive 靜態庫" >&2
    find "$build_dir" -name '*.lib' 2>/dev/null >&2 || true
    exit 1
fi

libarchive_version=$(git -C libarchive describe --tags --always)
libarchive_commit=$(git -C libarchive rev-parse HEAD)
tmp_version="version.txt.tmp"
{
    grep -vE '^libarchive_(version|commit|linkage)=' version.txt 2>/dev/null || true
    echo "libarchive_version=$libarchive_version"
    echo "libarchive_commit=$libarchive_commit"
    echo "libarchive_linkage=static"
} > "$tmp_version"
mv "$tmp_version" version.txt

echo "[OK] Built libarchive $libarchive_version ($libarchive_commit) / 已建置 libarchive 靜態庫"
