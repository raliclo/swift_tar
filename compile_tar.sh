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

BREW_LIB="/opt/homebrew/lib"
for lib in liblz4.dylib liblzma.dylib libzstd.dylib; do
    if [[ ! -e "$BREW_LIB/$lib" ]]; then
        echo "Missing $BREW_LIB/$lib — install with: brew install lz4 xz zstd" >&2
        echo "缺少 $BREW_LIB/$lib —— 請執行：brew install lz4 xz zstd" >&2
        exit 1
    fi
done

# Strip the top-level runCLI() entry point (not valid in multi-file builds)
# 剝除頂層 runCLI() 進入點（多檔編譯不允許頂層敘述）
TEMP_CLI="$(mktemp -t lzfse-cli-lib).swift"
trap 'rm -f "$TEMP_CLI"' EXIT
grep -v "^runCLI()$" lzfse2/lzfse-cli.swift > "$TEMP_CLI"

# Build into the release/ folder / 建置輸出至 release/ 資料夾
mkdir -p release
swiftc -O "$TEMP_CLI" swift_tar.swift -o release/swift_tar \
    -lz -lbz2 -L"$BREW_LIB" -llz4 -llzma -lzstd

echo "Built ./release/swift_tar / 已建置 ./release/swift_tar"

mkdir -p /opt/homebrew/bin
cp ./release/swift_tar /opt/homebrew/bin/swift_tar
echo "Installed to /opt/homebrew/bin/swift_tar / 已安裝至 /opt/homebrew/bin/swift_tar"
