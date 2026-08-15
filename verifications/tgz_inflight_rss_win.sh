#!/usr/bin/env zsh
# =====================================================================
# tgz_inflight_rss_win.sh — Windows counterpart of tgz_inflight_rss.sh:
# measure TGZ encode/decode peak working set vs -n (in-flight chunk
# concurrency) to confirm the Data append+removeFirst fix (see
# README.md) also helps on Windows, not just macOS.
# tgz_inflight_rss_win.sh —— tgz_inflight_rss.sh 的 Windows 對照版：量測
# TGZ encode/decode 的 peak working set 隨 -n（在途 chunk 並行數）如何
#變化，確認 Data append+removeFirst 修正（見 README.md）在 Windows 上
#是否也有幫助，而不只是 macOS。
#
# Windows has no `/usr/bin/time -l`; peak working set (the Windows
# equivalent of macOS "maximum resident set size") is measured via a
# companion PowerShell helper (measure_peak_ws_win.ps1) that reads
# Process.PeakWorkingSet64 after the child exits.
# Windows 沒有 `/usr/bin/time -l`；peak working set（對應 macOS
# "maximum resident set size"）改用旁邊的 PowerShell 輔助腳本
# （measure_peak_ws_win.ps1）量測，在子行程結束後讀取
# Process.PeakWorkingSet64。
#
# Usage / 用法：
#   swift_tar/verifications/tgz_inflight_rss_win.sh <path-to-corpus>
#
# Requires / 需求：swift_tar 已編譯至 release\swift_tar.exe
#   （執行 swift_tar\compile_tar-win.bat）。
# =====================================================================
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-$SCRIPT_DIR/../release/swift_tar.exe}"
MEASURE_PS1="$SCRIPT_DIR/measure_peak_ws_win.ps1"
CORPUS="${1:?Usage: $0 <path-to-corpus>}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Every run overwrites the sibling output file with this run's stdout.
# 每次執行都把本次 stdout 覆寫到同目錄的輸出檔。
OUTPUT_TXT="$SCRIPT_DIR/tgz_inflight_rss_win_output.txt"
exec > >(tee "$OUTPUT_TXT")

if [[ ! -x "$SWIFT_TAR_BIN" ]]; then
    echo "[Error] swift_tar not found at $SWIFT_TAR_BIN — run swift_tar/compile_tar-win.bat first." >&2
    exit 1
fi
if [[ ! -e "$CORPUS" ]]; then
    echo "[Error] corpus not found: $CORPUS" >&2
    exit 1
fi

measure() {
    # Usage: measure encode|decode <n> <archive> [corpus-or-dest]
    powershell -NoProfile -ExecutionPolicy Bypass -File "$MEASURE_PS1" \
        -Mode "$1" -Exe "$SWIFT_TAR_BIN" -N "$2" -Archive "$3" \
        $([ "$1" = "encode" ] && echo "-Corpus" || echo "-Dest") "$4"
}

echo "[Info] corpus: $CORPUS ($(du -sh "$CORPUS" | awk '{print $1}'))"
echo "[Info] swift_tar: $SWIFT_TAR_BIN"
echo

echo "== Encode: peak working set vs -n =="
echo "-n      real(s)   peakWS(bytes)   peakWS(GB)"
for n in 4 8 12 16 20 24 28 32 36 40; do
    archive="$TMP_DIR/encode-n${n}.tgz"
    out="$(measure encode "$n" "$archive" "$CORPUS")"
    real="${out%%|*}"
    ws="${out##*|}"
    gb="$(awk -v b="$ws" 'BEGIN{printf "%.2f", b/1073741824}')"
    printf "%-6s  %-8s  %-14s  %s\n" "$n" "$real" "$ws" "$gb"
    rm -f "$archive"
done

echo
echo "== Decode: peak working set vs -n =="
archive="$TMP_DIR/decode-src.tgz"
"$SWIFT_TAR_BIN" -c -z -f "$archive" -n 8 "$CORPUS"
echo "-n      real(s)   peakWS(bytes)   peakWS(GB)"
for n in 4 8 12 16 20 24 28 32 36 40; do
    dest="$TMP_DIR/decode-n${n}"
    mkdir -p "$dest"
    out="$(measure decode "$n" "$archive" "$dest")"
    real="${out%%|*}"
    ws="${out##*|}"
    gb="$(awk -v b="$ws" 'BEGIN{printf "%.2f", b/1073741824}')"
    printf "%-6s  %-8s  %-14s  %s\n" "$n" "$real" "$ws" "$gb"
    rm -rf "$dest"
done

echo
echo "[Info] Compare against tgz_inflight_rss_output.txt (macOS) — see README.md"
echo "       for the pre-fix vs post-fix summary table."
