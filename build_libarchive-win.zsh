#!/usr/bin/env zsh
# Build the bundled static libarchive ZIP backend with clang-cl for Windows.
# 使用 clang-cl 建置 Windows 使用的內附靜態 libarchive ZIP 後端。
#
#   zsh ./build_libarchive-win.zsh          build it; run build_zlib-win.zsh first
#                                           建置；須先執行 build_zlib-win.zsh
#   zsh ./build_libarchive-win.zsh --help   print this synopsis and exit
#                                           印出本說明後結束
set -eu

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,8p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

# Never moves a checked-out submodule; see submodule_pins.zsh. / 絕不移動已 checkout 的子模組；見 submodule_pins.zsh。
. ./submodule_pins.zsh
ensure_submodule_pins libarchive zlib || exit 1

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
#
# Compiler: the Swift toolchain's clang-cl, not MSVC cl.exe (2026-10-30, with zlib and zstd moving to
# clang; measured in verifications/win_clang_deps.zsh). clang-cl rather than the GNU driver because
# libarchive's CMake then keeps its MSVC branch -- /WX, its warning set, the archive.lib name -- and
# -utf-8 still means what the paragraph above says. clang-cl's /O2 already implies /Gy.
# win_clang_cmake.zsh (NMake, not Visual Studio) keeps the library at libarchive/Release/, where
# compile_tar-win.zsh looks.
# 編譯器：Swift 工具鏈的 clang-cl，而非 MSVC cl.exe（2026-10-30，隨 zlib 與 zstd 改用 clang；量測見
# verifications/win_clang_deps.zsh）。選 clang-cl 而非 GNU 驅動，是因為這樣 libarchive 的 CMake 仍走
# MSVC 分支——/WX、它的警告組合、archive.lib 的檔名——而 -utf-8 的意義仍如上段所述。clang-cl 的 /O2
# 已隱含 /Gy。win_clang_cmake.zsh（NMake，而非 Visual Studio）讓靜態庫仍在 compile_tar-win.zsh 尋找的
# libarchive/Release/。
. ./win_clang_cmake.zsh
win_clang_cmake clang-cl "$SCRIPT_DIR/$build_dir/libarchive/Release" || exit 1
# This build tree is incremental (compile_tar-win.zsh runs this every time), and CMake refuses to
# reuse a tree made by another generator or compiler. Start over once when either differs, e.g. a
# tree left by the earlier Visual Studio build. / 此建置樹是增量的（compile_tar-win.zsh 每次都會執行
# 本腳本），而 CMake 拒絕沿用以其他產生器或編譯器建立的樹。兩者任一不同時（例如先前 Visual Studio
# 建置留下的樹）重來一次。
cache="$build_dir/CMakeCache.txt"
if [ -f "$cache" ] && ! { grep -qxF 'CMAKE_GENERATOR:INTERNAL=NMake Makefiles' "$cache" &&
                          grep -qxF "CMAKE_C_COMPILER:STRING=$win_cc" "$cache"; }; then
    echo "[Info] $build_dir was configured differently; removing it / 設定不同，移除重建"
    rm -rf -- "$build_dir"
fi
cmake -S libarchive -B "$build_dir" "${win_cmake_args[@]}" \
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
cmake --build "$build_dir" --target archive_static

archive_lib="$build_dir/libarchive/Release/archive.lib"
if [ ! -f "$archive_lib" ]; then
    echo "[FAIL] $archive_lib not found / 找不到 libarchive 靜態庫" >&2
    # A zsh glob, not `find`: after the vcvars PATH is in front, `find` is C:\Windows\System32\find.exe,
    # a text search, so this listing printed nothing just when it was needed (its error went to
    # 2>/dev/null). / 用 zsh glob 而非 `find`：vcvars 的 PATH 放到前面後，`find` 是
    # C:\Windows\System32\find.exe（文字搜尋），於是這份清單偏偏在需要時什麼都不印（錯誤被 2>/dev/null 吞掉）。
    print -rl -- "$build_dir"/**/*.lib(N) >&2
    exit 1
fi

libarchive_version=$(git -C libarchive describe --tags --always)
libarchive_commit=$(git -C libarchive rev-parse HEAD)
version_file="version-win.txt"
# grep's status 1 (nothing printed) is the only one tolerated; see build_zlib-win.zsh.
# Was `2>/dev/null || true`, which also swallowed a real error (2026-09-27).
# 僅容忍 grep 的狀態 1（沒有輸出），理由見 build_zlib-win.zsh。原本是
# `2>/dev/null || true`，連真正的錯誤也一併吞掉（2026-09-27）。
[ -f "$version_file" ] || { echo "[FAIL] $version_file missing / 找不到 $version_file" >&2; exit 1; }
tmp_version="$version_file.tmp"
{
    grep -vE '^libarchive_(version|commit|linkage)=' "$version_file" || [ $? -eq 1 ]
    echo "libarchive_version=$libarchive_version"
    echo "libarchive_commit=$libarchive_commit"
    echo "libarchive_linkage=static"
} > "$tmp_version"
mv "$tmp_version" "$version_file"

echo "[OK] Built libarchive $libarchive_version ($libarchive_commit) / 已建置 libarchive 靜態庫"
