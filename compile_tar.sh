#!/bin/zsh
# =====================================================================
# compile_tar.sh — build swift_tar (multi-core tar archiver)
# compile_tar.sh — 編譯 swift_tar（多核心 tar 打包工具）
#
# Reuses lzfse-cli.swift as a library (same pattern as lzfse-ui/build-ui.sh:
# strip the top-level runCLI() entry point, then compile both files together).
# 將 lzfse-cli.swift 當函式庫重用（同 lzfse-ui/build-ui.sh 模式：剝除頂層
# runCLI() 進入點後兩檔合併編譯）。
#
# Links / 連結：
#   -lz      : zlib (SDK)            — gzip members / gzip 成員
#   -lbz2    : libbz2 (SDK)          — bzip2 streams / bzip2 串流
#   -llzma   : liblzma (homebrew xz) — xz / lzma / lzip
#   -lzstd   : libzstd (homebrew)    — zstd frames
#   -llz4    : liblz4 (homebrew)     — standard LZ4 frames / 標準 LZ4 frame
#
# Output / 輸出：release/swift_tar
# =====================================================================
set -e
cd "$(dirname "$0")"
. ./platform.sh

# Optional: --no-lzfse builds the public/distributable binary that ships NONE of
# the private LZFSE engine — lzfse-cli.swift is not compiled in, and the binary
# can neither create nor decode any LZFSE-family archive (other3/bvx3/bvx2).
# The standard external codecs (gzip/bzip2/xz/zstd/lz4) and plain tar remain.
# 選用：--no-lzfse 產生「公開／可散布」版本，完全不含私有 LZFSE 引擎——不編譯
# lzfse-cli.swift，產出的 binary 既不能建立也不能解碼任何 LZFSE 家族封存
# （other3/bvx3/bvx2）；標準外部 codec（gzip/bzip2/xz/zstd/lz4）與純 tar 仍保留。
SWIFT_DEFINES=""
EXCLUDE_LZFSE=0
for arg in "$@"; do
    case "$arg" in
        --no-lzfse) EXCLUDE_LZFSE=1; SWIFT_DEFINES="-DEXCLUDE_LZFSE" ;;
    esac
done
if [[ "$EXCLUDE_LZFSE" == 1 ]]; then
    echo "Excluding the private LZFSE engine (EXCLUDE_LZFSE): lzfse-cli.swift not compiled / 排除私有 LZFSE 引擎：不編譯 lzfse-cli.swift"
fi

BREW_LIB="/opt/homebrew/lib"
for lib in liblz4.dylib liblzma.dylib libzstd.dylib; do
    if [[ ! -e "$BREW_LIB/$lib" ]]; then
        echo "Missing $BREW_LIB/$lib — install with: brew install lz4 xz zstd" >&2
        echo "缺少 $BREW_LIB/$lib —— 請執行：brew install lz4 xz zstd" >&2
        exit 1
    fi
done

# Include lzfse-cli.swift as a library only when LZFSE is not excluded. Strip its
# top-level runCLI() entry point (not valid in multi-file builds).
# 僅在未排除 LZFSE 時才把 lzfse-cli.swift 當函式庫納入；剝除其頂層 runCLI()
# 進入點（多檔編譯不允許頂層敘述）。
TEMP_CLI=""
CLI_SRC=""
if [[ "$EXCLUDE_LZFSE" != 1 ]]; then
    if [[ ! -f lzfse2/lzfse-cli.swift ]]; then
        echo "Error: lzfse2 submodule not found (lzfse2/lzfse-cli.swift is missing)." >&2
        echo "       Fetch it with: git submodule update --init" >&2
        echo "       Or compile WITHOUT LZFSE support instead: ./compile_no_lzfse.sh" >&2
        echo "錯誤：找不到 lzfse2 submodule（缺少 lzfse2/lzfse-cli.swift）。" >&2
        echo "      請執行：git submodule update --init 取得" >&2
        echo "      或改為「不含 LZFSE 支援」編譯：./compile_no_lzfse.sh" >&2
        exit 1
    fi
    TEMP_CLI="$(mktemp -t lzfse-cli-lib).swift"
    grep -v "^runCLI()$" lzfse2/lzfse-cli.swift > "$TEMP_CLI"
    CLI_SRC="$TEMP_CLI"
fi
TEMP_VERSION="$(mktemp -t swift-tar-version).swift"
trap 'rm -f "$TEMP_CLI" "$TEMP_VERSION"' EXIT
sh ./generate_version.sh "$TEMP_VERSION"

# Build into the release/ folder / 建置輸出至 release/ 資料夾
mkdir -p release
sh ./build_libarchive.sh
swiftc -O $SWIFT_DEFINES $CLI_SRC "$TEMP_VERSION" swift_tar.swift rgb1.swift crypto.swift \
    build/libarchive_zip_bridge.o build/libarchive-macos/libarchive/libarchive.a \
    -o release/swift_tar -lz -lbz2 -L"$BREW_LIB" -llz4 -llzma -lzstd

echo "Built ./release/swift_tar / 已建置 ./release/swift_tar"

# Record what the binary actually links, read back from the binary itself. otool
# names the dylib that will be loaded at run time, which is the only version a
# provenance record can honestly mean — a header or a `brew list` can describe
# something the linker did not pick. libarchive is absent here because it is
# static; build_libarchive.sh records it from the submodule's own gitlink, the
# same way the Windows builders do.
# 記錄執行檔實際連結了什麼，且直接自執行檔讀回。otool 指出的是執行時會載入的 dylib，
# 那是 provenance 紀錄唯一能誠實表達的版本——標頭檔或 `brew list` 描述的可能是連結器
# 根本沒選用的那一份。此處沒有 libarchive，因為它是靜態連結；build_libarchive.sh 會
# 依 submodule 自身的 gitlink 記錄它，與 Windows 建置腳本作法相同。
#
# The version recorded is the Mach-O "current version" of the dylib, hence the
# key name. For zlib, bzip2, lz4 and zstd it happens to equal the upstream
# release; for liblzma it does not — xz 5.x ships a dylib numbered 14.3.0. Naming
# the field after what it actually is keeps that from reading as a wrong xz
# version. The path is the identifying half of the record anyway.
# 所記錄的版本是該 dylib 的 Mach-O「current version」，鍵名即據此命名。zlib、bzip2、
# lz4 與 zstd 恰好與上游發行版號相同，liblzma 則否——xz 5.x 的 dylib 版號為 14.3.0。
# 依欄位的實際含意命名，可避免它被誤讀為錯誤的 xz 版本。何況真正用於辨識的是路徑。
record_linked() {        # key  first-field pattern / 鍵名 與 第一欄比對樣式
    otool -L release/swift_tar | awk -v k="$1" -v pat="$2" '
        $1 ~ pat {
            v = $0; sub(/.*current version /, "", v); sub(/\).*/, "", v)
            printf "%s_dylib_version=%s\n%s_path=%s\n%s_linkage=dynamic\n", k, v, k, $1, k
            exit
        }'
}
version_file="version-$(swift_tar_platform).txt"
tmp_version="$version_file.tmp"
{
    grep -vE '^(zlib|bzip2|lz4|xz|zstd)_(dylib_version|path|linkage)=' "$version_file" 2>/dev/null || true
    record_linked zlib  'libz\.'
    record_linked bzip2 'libbz2\.'
    record_linked lz4   'liblz4\.'
    record_linked xz    'liblzma\.'
    record_linked zstd  'libzstd\.'
} > "$tmp_version"
mv "$tmp_version" "$version_file"
echo "Recorded linked libraries in $version_file / 已將連結的函式庫記入 $version_file"

mkdir -p /opt/homebrew/bin
cp ./release/swift_tar /opt/homebrew/bin/swift_tar
echo "Installed to /opt/homebrew/bin/swift_tar / 已安裝至 /opt/homebrew/bin/swift_tar"
