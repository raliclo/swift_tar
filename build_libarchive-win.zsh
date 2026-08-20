#!/usr/bin/env zsh
# Build the bundled static libarchive ZIP backend with MSVC for Windows.
# 使用 MSVC 建置 Windows 使用的內附靜態 libarchive ZIP 後端。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

git submodule update --init libarchive zlib

if [ ! -f zlib/build/Release/zs.lib ]; then
    echo "[FAIL] zlib/build/Release/zs.lib not found; run zsh ./build_zlib-win.zsh" >&2
    exit 1
fi

build_dir="build/libarchive-win"

# The compiler flag below is spelled -utf-8, not //utf-8.
#
# cl.exe accepts either prefix, but a doubled slash is a request to MSYS rather
# than to the compiler: MSYS rewrites //x to /x only while it is doing argument
# conversion. A shell started outside that path -- by PowerShell's Start-Process,
# for one -- passes //utf-8 through verbatim, cl.exe does not recognise it, and
# the sources are then read in the system ANSI code page. Any file holding a byte
# that page cannot represent stops the build: on a CP950 machine
# archive_read_support_format_rar5.c raised C4819, which becomes C2220 here
# because libarchive builds with /WX.
#
# It needs a non-UTF-8 ACP *and* an actual recompile, so a cached archive.lib hid
# it for as long as nothing invalidated the build tree.
#
# 下面那個編譯器旗標寫成 -utf-8，而非 //utf-8。
#
# cl.exe 兩種前綴都接受，但雙斜線是說給 MSYS 聽的、不是說給編譯器聽的：MSYS 只在進行
# 引數轉換時才會把 //x 改寫成 /x。在該路徑之外啟動的 shell——例如由 PowerShell 的
# Start-Process 啟動者——會原樣傳遞 //utf-8，cl.exe 不認得它，於是原始碼改以系統 ANSI
# 字碼頁讀取。任何含有該字碼頁無法表示之位元組的檔案都會中止建置：在 CP950 的機器上，
# archive_read_support_format_rar5.c 觸發 C4819，而此處 libarchive 以 /WX 建置，
# 該警告即成為 C2220。
#
# 它同時需要非 UTF-8 的 ACP 與一次真正的重編，因此只要沒有東西讓建置樹失效，
# 一份快取的 archive.lib 就會一直把它遮住。
cmake -S libarchive -B "$build_dir" -G "Visual Studio 17 2022" -A x64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DMSVC_USE_STATIC_CRT=OFF \
    -DCMAKE_C_FLAGS=-utf-8 \
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
version_file="version-win.txt"
tmp_version="$version_file.tmp"
{
    grep -vE '^libarchive_(version|commit|linkage)=' "$version_file" 2>/dev/null || true
    echo "libarchive_version=$libarchive_version"
    echo "libarchive_commit=$libarchive_commit"
    echo "libarchive_linkage=static"
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built libarchive $libarchive_version ($libarchive_commit) / 已建置 libarchive 靜態庫"
