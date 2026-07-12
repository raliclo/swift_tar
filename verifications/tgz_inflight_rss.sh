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
# Findings (full sweep, n=4..40 step 4, claw-code corpus) / 實測結果（完整
# 掃描，n=4..40 step 4，claw-code 語料）：
#   Encode: RSS is flat ~2.1-2.6GB across every n, no monotonic trend with
#     concurrency. -n does not appear to be the primary driver of
#     encode-side peak RSS. **Encode-side driver is unconfirmed.**
#   Decode: RSS ramps from n=4 (2.51GB) -> n=12 (2.99GB) then plateaus
#     ~3.0GB through n=40, with no time penalty at low n (2.7-4.0s across
#     the board, no clear pattern) — n=4 is a decode-side free win, saves
#     ~500MB vs the n>=12 plateau.
#   Encode：RSS 在所有 n 間打平在 2.1-2.6GB，無單調趨勢——`-n` 看起來不是
#     encode 端 peak RSS 的主要驅動因子。**encode 端的驅動因子尚未確認。**
#   Decode：RSS 從 n=4（2.51GB）爬升到 n=12（2.99GB）後打平在 ~3.0GB 直到
#     n=40，且低 n 沒有時間代價（各 n 都落在 2.7-4.0s，無明顯規律）——
#     n=4 對 decode 是免費的優化，比 n>=12 的飽和值省約 500MB。
#
# Rerun and compare before trusting or acting on any single sweep. /
# 採信或依此行動前，請先重跑比對。
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
