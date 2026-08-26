#!/usr/bin/env zsh
# Build the bundled static libarchive ZIP backend for macOS or Linux.
# 建置 macOS 或 Linux 使用的內附靜態 libarchive ZIP 後端。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"
. ./platform.zsh

git submodule update --init libarchive

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
