#!/bin/zsh
# =====================================================================
# tgz_inflight_rss.sh — measure TGZ encode/decode peak RSS vs -n (in-flight
# chunk concurrency) to confirm concurrency is the primary memory driver.
# tgz_inflight_rss.sh —— 量測 TGZ encode/decode 的 peak RSS 隨 -n（在途
# chunk 並行數）如何變化，驗證並行度是主要的記憶體驅動因子。
#
# Background / 背景：
#   getar() in zshrc.sh calls `tar czf` (shimmed to swift_tar) without -n,
#   so swift_tar falls back to its default inflight = cores*2 (capped at
#   cores*4; 20 on the 10-core R45-Mac test machine).
#   zshrc.sh 的 getar() 呼叫 `tar czf`（被 shim 成 swift_tar）時沒有帶
#   -n，因此 swift_tar 會退回預設值 inflight = cores*2（上限 cores*4；
#   R45-Mac 測試機 10 核心 → 預設 20）。
#
# Findings (claw-code corpus, n=4..40 step 4) / 實測結果（claw-code 語料，
# n=4..40 step 4）：
#   Pre-fix: encode ~2.1-2.6GB / decode ~2.5-3.0GB, both roughly corpus-
#     sized and insensitive to -n — the signature of Foundation
#     FileHandle.read autorelease accumulation in tight CLI loops.
#   Fix (2026-07-12): wrapped the hot read/write loops in autoreleasepool
#     (TarWriter.add, ParallelChunkSink.dispatch, gzipDecodeStream,
#     TarReader.readExactly, extract write loop, drain loop) — the same
#     pattern lzfse-cli.swift already used, which is why the LZFSE formats
#     never had this problem.
#   Post-fix: encode ~1.0-1.4GB (-45%), decode ~1.2-1.4GB (-55%), flat
#     across all n, no time regression. The earlier "n=4 decode free win"
#     disappeared post-fix — it was a side effect of the leak.
#   修正前：encode ~2.1-2.6GB／decode ~2.5-3.0GB，皆接近語料大小且對 -n
#     不敏感——這是 Foundation FileHandle.read 在 CLI 緊密迴圈中
#     autorelease 累積的典型特徵。
#   修正（2026-07-12）：把熱讀寫迴圈包進 autoreleasepool（TarWriter.add、
#     ParallelChunkSink.dispatch、gzipDecodeStream、TarReader.readExactly、
#     解壓寫檔迴圈、收尾 drain 迴圈）——與 lzfse-cli.swift 既有模式相同，
#     這也是 LZFSE 格式從未出現此問題的原因。
#   修正後：encode ~1.0-1.4GB（-45%）、decode ~1.2-1.4GB（-55%），各 n 間
#     打平，無時間退化。先前的「decode n=4 免費優化」在修正後消失——
#     那其實是洩漏的副作用。
#
# Usage / 用法：
#   swift_tar/verifications/tgz_inflight_rss.sh <path-to-corpus>
#
# Requires / 需求：swift_tar 已編譯至 /opt/homebrew/bin/swift_tar
#   （執行 swift_tar/compile_tar.sh）。
# =====================================================================
set -euo pipefail

SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-/opt/homebrew/bin/swift_tar}"
CORPUS="${1:?Usage: $0 <path-to-corpus>}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Every run overwrites the sibling output file with this run's stdout.
# 每次執行都把本次 stdout 覆寫到同目錄的輸出檔。
OUTPUT_TXT="${0:A:h}/tgz_inflight_rss_output.txt"
exec > >(tee "$OUTPUT_TXT")

if [[ ! -x "$SWIFT_TAR_BIN" ]]; then
    echo "[Error] swift_tar not found at $SWIFT_TAR_BIN — run swift_tar/compile_tar.sh first." >&2
    exit 1
fi
if [[ ! -e "$CORPUS" ]]; then
    echo "[Error] corpus not found: $CORPUS" >&2
    exit 1
fi

echo "[Info] corpus: $CORPUS ($(du -sh "$CORPUS" | awk '{print $1}'))"
echo "[Info] swift_tar: $SWIFT_TAR_BIN"
echo

echo "== Encode: peak RSS vs -n =="
echo "-n      real(s)   maxRSS(bytes)   maxRSS(GB)"
for n in 4 8 12 16 20 24 28 32 36 40; do
    archive="$TMP_DIR/encode-n${n}.tgz"
    out="$(/usr/bin/time -l "$SWIFT_TAR_BIN" -c -z -f "$archive" -n "$n" "$CORPUS" 2>&1 >/dev/null)"
    real="$(echo "$out" | awk '/real/{print $1}')"
    rss="$(echo "$out" | awk '/maximum resident set size/{print $1}')"
    gb="$(awk -v b="$rss" 'BEGIN{printf "%.2f", b/1073741824}')"
    printf "%-6s  %-8s  %-14s  %s\n" "$n" "$real" "$rss" "$gb"
    rm -f "$archive"
done

echo
echo "== Decode: peak RSS vs -n =="
archive="$TMP_DIR/decode-src.tgz"
"$SWIFT_TAR_BIN" -c -z -f "$archive" -n 8 "$CORPUS"
echo "-n      real(s)   maxRSS(bytes)   maxRSS(GB)"
for n in 4 8 12 16 20 24 28 32 36 40; do
    dest="$TMP_DIR/decode-n${n}"
    mkdir -p "$dest"
    out="$(/usr/bin/time -l "$SWIFT_TAR_BIN" -x -z -f "$archive" -C "$dest" -n "$n" 2>&1 >/dev/null)"
    real="$(echo "$out" | awk '/real/{print $1}')"
    rss="$(echo "$out" | awk '/maximum resident set size/{print $1}')"
    gb="$(awk -v b="$rss" 'BEGIN{printf "%.2f", b/1073741824}')"
    printf "%-6s  %-8s  %-14s  %s\n" "$n" "$real" "$rss" "$gb"
    rm -rf "$dest"
done

echo
echo "[Info] Encode RSS vs -n has been INCONSISTENT across repeated sweeps in this"
echo "       repo (see header) — don't trust a single run's trend for encode."
echo "[Info] Decode RSS has been more consistent: ramps n=4 -> n~=12 then plateaus."
echo "       Compare this run's numbers against the header notes before concluding."
