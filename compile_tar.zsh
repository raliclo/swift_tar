#!/bin/zsh
# =====================================================================
# compile_tar.zsh — build swift_tar (multi-core tar archiver)
# compile_tar.zsh — 編譯 swift_tar（多核心 tar 打包工具）
#
# Reuses lzfse-cli.swift as a library (same pattern as lzfse-ui/build-ui.zsh:
# strip the top-level runCLI() entry point, then compile both files together).
# 將 lzfse-cli.swift 當函式庫重用（同 lzfse-ui/build-ui.zsh 模式：剝除頂層
# runCLI() 進入點後兩檔合併編譯）。
#
# Links / 連結：
#   -lz        : zlib (SDK, dynamic)     — gzip members / gzip 成員
#   -lbz2      : libbz2 (SDK, dynamic)   — bzip2 streams / bzip2 串流
#   liblzma.a  : xz submodule (static)   — xz / lzma / lzip
#   libzstd.a  : zstd submodule (static) — zstd frames
#   liblz4.a   : lz4 submodule (static)  — standard LZ4 frames / 標準 LZ4 frame
#
# The three codec libraries are built from this tree's own submodules by
# build_codecs.zsh, not taken from homebrew; that script records why.
# 三個 codec 函式庫由本樹自己的 submodule 經 build_codecs.zsh 建出，而非取自
# homebrew；理由記於該腳本。
#
# Output / 輸出：release/swift_tar
#
# Usage / 用法:
#   ./compile_tar.zsh [--no-lzfse]   build; --no-lzfse omits the private engine
#                                    建置；--no-lzfse 不含私有引擎
#   ./compile_tar.zsh --help         print this synopsis and exit, building nothing
#                                    印出本說明後結束，不進行任何建置
# =====================================================================
set -e

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '3,29p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

cd "$(dirname "$0")"
. ./platform.zsh

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
        echo "       Or compile WITHOUT LZFSE support instead: ./compile_no_lzfse.zsh" >&2
        echo "錯誤：找不到 lzfse2 submodule（缺少 lzfse2/lzfse-cli.swift）。" >&2
        echo "      請執行：git submodule update --init 取得" >&2
        echo "      或改為「不含 LZFSE 支援」編譯：./compile_no_lzfse.zsh" >&2
        exit 1
    fi
    TEMP_CLI="$(mktemp -t lzfse-cli-lib).swift"
    grep -v "^runCLI()$" lzfse2/lzfse-cli.swift > "$TEMP_CLI"
    CLI_SRC="$TEMP_CLI"
fi
TEMP_VERSION="$(mktemp -t swift-tar-version).swift"
trap 'rm -f "$TEMP_CLI" "$TEMP_VERSION"' EXIT

# Build into the release/ folder / 建置輸出至 release/ 資料夾
mkdir -p release

# The dependency builders run BEFORE generate_version.zsh, not after.
#
# generate_version.zsh decides whether to issue a new build stamp by comparing the
# rest of version-<plat>.txt against the committed copy: unchanged provenance reuses
# the stamp, so a rebuild of identical inputs does not produce a spurious diff. But
# these two scripts are what write that provenance. Called after, they hand
# generate_version.zsh the PREVIOUS build's dependency versions, and the stamp is
# reused even when a submodule pin has moved.
#
# Caught on 2026-09-20 upgrading xz e38f738e → 3b1efb04 (5.8.3 → 5.8.4): version-mac.txt
# correctly recorded the new commit, while `swift_tar --version` still reported
# 20260917-065248 — the same string as the binary containing the older liblzma. Nothing
# failed; the two binaries simply became indistinguishable by the field that exists to
# distinguish them.
#
# zlib and bzip2 stay one build behind by necessity: their record is read back from the
# finished binary with otool, which cannot happen before the stamp is compiled into it.
# They come from the SDK and move only with the OS.
#
# 相依建置腳本要在 generate_version.zsh **之前**執行，不是之後。
#
# generate_version.zsh 以「version-<平台>.txt 的其餘內容與已提交版本是否相同」決定要不要
# 發新的建置戳記：provenance 未變就重用戳記，使輸入相同的重建不產生多餘 diff。但寫入那份
# provenance 的正是這兩支腳本。放在後面呼叫，等於把**上一次**建置的相依版本交給
# generate_version.zsh，於是即使 submodule pin 已經移動，戳記仍被重用。
#
# 2026-09-20 升級 xz e38f738e → 3b1efb04（5.8.3 → 5.8.4）時發現：version-mac.txt 正確記下
# 了新 commit，而 `swift_tar --version` 仍回報 20260917-065248——與內含舊 liblzma 的那個
# 執行檔同一個字串。沒有任何一步失敗，只是兩個執行檔在「用來區分它們的那個欄位」上再也分不開。
#
# zlib 與 bzip2 必然落後一次建置：它們的紀錄是以 otool 自完成的執行檔讀回，而那不可能發生在
# 戳記被編進去之前。兩者取自 SDK，只隨 OS 變動。
zsh ./build_libarchive.zsh
zsh ./build_codecs.zsh

# zsh, not sh: both callees declare `#!/usr/bin/env zsh`, and `sh script`
# ignores the shebang. Running a zsh script under sh works only for as long as
# it happens to stay POSIX — the moment either one uses `print`, a `(N)` glob
# qualifier or `${0:A:h}`, it breaks somewhere unrelated to the change that
# introduced it.
# 使用 zsh 而非 sh：兩個被呼叫的腳本都宣告 `#!/usr/bin/env zsh`，而 `sh script`
# 會忽略 shebang。以 sh 執行 zsh 腳本，只在它剛好維持 POSIX 的期間內可行——一旦
# 其中任一支用了 `print`、`(N)` glob qualifier 或 `${0:A:h}`，就會在與該改動
# 毫無關聯之處失敗。
zsh ./generate_version.zsh "$TEMP_VERSION"

swiftc -O -swift-version 6 $SWIFT_DEFINES $CLI_SRC "$TEMP_VERSION" swift_tar.swift rgb1.swift crypto.swift \
    build/libarchive_zip_bridge.o build/libarchive-macos/libarchive/libarchive.a \
    build/xz-macos/liblzma.a build/lz4-macos/liblz4.a build/zstd-macos/lib/libzstd.a \
    -o release/swift_tar -lz -lbz2

echo "Built ./release/swift_tar / 已建置 ./release/swift_tar"

# Record what the binary actually links, read back from the binary itself. otool
# names the dylib that will be loaded at run time, which is the only version a
# provenance record can honestly mean — a header or a `brew list` can describe
# something the linker did not pick. libarchive is absent here because it is
# static; build_libarchive.zsh records it from the submodule's own gitlink, the
# same way the Windows builders do.
# 記錄執行檔實際連結了什麼，且直接自執行檔讀回。otool 指出的是執行時會載入的 dylib，
# 那是 provenance 紀錄唯一能誠實表達的版本——標頭檔或 `brew list` 描述的可能是連結器
# 根本沒選用的那一份。此處沒有 libarchive，因為它是靜態連結；build_libarchive.zsh 會
# 依 submodule 自身的 gitlink 記錄它，與 Windows 建置腳本作法相同。
#
# Only zlib and bzip2 are read back this way now. lz4, xz and zstd left the dylib
# world when they moved to the submodule builds, so build_codecs.zsh records their
# gitlinks instead -- and the filter below must NOT strip those keys, or each build
# would delete a record it has no way to rewrite.
# 現在只有 zlib 與 bzip2 以此方式讀回。lz4、xz 與 zstd 改由 submodule 建置後已不再是
# dylib，故改由 build_codecs.zsh 記錄其 gitlink——而下方的過濾器**不得**刪掉那些鍵，
# 否則每次建置都會刪去一筆自己無從重寫的紀錄。
#
# The version recorded is the Mach-O "current version" of the dylib, hence the
# key name. For zlib and bzip2 it happens to equal the upstream release; it does
# not always — xz 5.x shipped a dylib numbered 14.3.0, which is what made this
# naming necessary in the first place. The path is the identifying half anyway.
# 所記錄的版本是該 dylib 的 Mach-O「current version」，鍵名即據此命名。zlib 與 bzip2
# 恰好與上游發行版號相同，但並非總是如此——xz 5.x 的 dylib 版號為 14.3.0，那正是當初
# 需要這種命名的原因。何況真正用於辨識的是路徑。
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
    grep -vE '^(zlib|bzip2)_(dylib_version|path|linkage)=' "$version_file" 2>/dev/null || true
    record_linked zlib  'libz\.'
    record_linked bzip2 'libbz2\.'
} > "$tmp_version"
mv "$tmp_version" "$version_file"
echo "Recorded linked libraries in $version_file / 已將連結的函式庫記入 $version_file"

mkdir -p /opt/homebrew/bin
cp ./release/swift_tar /opt/homebrew/bin/swift_tar
echo "Installed to /opt/homebrew/bin/swift_tar / 已安裝至 /opt/homebrew/bin/swift_tar"
