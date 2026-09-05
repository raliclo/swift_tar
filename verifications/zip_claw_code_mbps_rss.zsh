#!/bin/zsh
# =====================================================================
# zip_claw_code_mbps_rss.zsh -- verify true-ZIP encode/decode throughput,
# peak RSS, and extracted-data correctness with the claw-code corpus.
# zip_claw_code_mbps_rss.zsh -- 使用 claw-code 語料驗證真實 ZIP encode/decode
# 吞吐量、peak RSS 與解壓內容正確性。
#
# Usage / 用法：
#   ROUNDS=3 ./zip_claw_code_mbps_rss.zsh ../../claw-code
#
# MB/s uses the corpus's logical regular-file bytes, not ZIP size. RSS is the
# maximum resident set size reported for the swift_tar process itself.
# MB/s 以語料內一般檔案的 logical bytes 計算，不使用 ZIP 大小；RSS 是
# swift_tar 程序本身回報的 maximum resident set size。
# =====================================================================
set -euo pipefail

# --help answers before any work starts / --help 在任何工作開始前先回答。
script_path="${0:A}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,15p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR="${0:A:h}"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-${SCRIPT_DIR:h}/release/swift_tar}"
CORPUS="${1:-${SCRIPT_DIR:h:h}/claw-code}"
ROUNDS="${ROUNDS:-3}"
OUTPUT_TXT="$SCRIPT_DIR/zip_claw_code_mbps_rss_output.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
exec > >(tee "$OUTPUT_TXT") 2>&1

if [[ ! -x "$SWIFT_TAR_BIN" ]]; then
    echo "[Error] swift_tar not found: $SWIFT_TAR_BIN / 找不到 swift_tar" >&2
    exit 1
fi
if [[ ! -d "$CORPUS" ]]; then
    echo "[Error] corpus not found: $CORPUS / 找不到測試語料" >&2
    exit 1
fi
if ! [[ "$ROUNDS" =~ '^[1-9][0-9]*$' ]]; then
    echo "[Error] ROUNDS must be a positive integer / ROUNDS 必須為正整數" >&2
    exit 1
fi
if [[ ! -x /usr/bin/time ]]; then
    echo "[Error] /usr/bin/time -l is required / 需要 macOS /usr/bin/time -l" >&2
    exit 1
fi

CORPUS="${CORPUS:A}"
CORPUS_PARENT="${CORPUS:h}"
CORPUS_LEAF="${CORPUS:t}"
RAW_BYTES="$(find "$CORPUS" -type f -exec stat -f '%z' {} + | awk '{sum += $1} END {printf "%.0f", sum}')"
FILE_COUNT="$(find "$CORPUS" -type f | wc -l | tr -d ' ')"
RAW_MB="$(awk -v bytes="$RAW_BYTES" 'BEGIN {printf "%.2f", bytes / 1000000}')"
ARCHIVE="$TMP_DIR/claw-code.zip"

typeset MEASURE_REAL MEASURE_RSS
measure() {
    local log="$TMP_DIR/time-$RANDOM.log"
    if ! /usr/bin/time -l "$@" >/dev/null 2>"$log"; then
        cat "$log" >&2
        return 1
    fi
    MEASURE_REAL="$(awk '$2 == "real" {print $1; exit}' "$log")"
    MEASURE_RSS="$(awk '/maximum resident set size/ {print $1; exit}' "$log")"
    if [[ -z "$MEASURE_REAL" || -z "$MEASURE_RSS" ]]; then
        cat "$log" >&2
        echo "[Error] failed to parse elapsed time or RSS / 無法解析時間或 RSS" >&2
        return 1
    fi
}

median() {
    printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END {if (NR%2) print v[(NR+1)/2]; else printf "%.6f\n", (v[NR/2]+v[NR/2+1])/2}'
}

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
echo "[Info] machine / 機器: $(uname -m), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
echo "[Info] swift_tar: $SWIFT_TAR_BIN ($("$SWIFT_TAR_BIN" --version))"
echo "[Info] corpus / 語料: $CORPUS"
echo "[Info] regular files / 一般檔案: $FILE_COUNT"
echo "[Info] logical input / 邏輯輸入: $RAW_BYTES bytes ($RAW_MB MB)"
echo "[Info] rounds / 輪數: $ROUNDS"
echo
printf "%-7s %-7s %10s %12s %12s\n" "phase" "round" "real(s)" "MB/s" "peakRSS(MB)"

typeset -a ENCODE_SECONDS ENCODE_SPEEDS ENCODE_RSS_MB
typeset -a DECODE_SECONDS DECODE_SPEEDS DECODE_RSS_MB

for round in $(seq 1 "$ROUNDS"); do
    measure "$SWIFT_TAR_BIN" -c --zip -f "$ARCHIVE" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
    seconds="$MEASURE_REAL"
    speed="$(awk -v bytes="$RAW_BYTES" -v sec="$seconds" 'BEGIN {printf "%.2f", (sec > 0 ? bytes/1000000/sec : 0)}')"
    rss_mb="$(awk -v bytes="$MEASURE_RSS" 'BEGIN {printf "%.2f", bytes/1000000}')"
    ENCODE_SECONDS+=("$seconds")
    ENCODE_SPEEDS+=("$speed")
    ENCODE_RSS_MB+=("$rss_mb")
    printf "%-7s %-7s %10.2f %12.2f %12.2f\n" "encode" "$round" "$seconds" "$speed" "$rss_mb"

    dest="$TMP_DIR/decode-$round"
    mkdir -p "$dest"
    measure "$SWIFT_TAR_BIN" -x -f "$ARCHIVE" -C "$dest"
    seconds="$MEASURE_REAL"
    speed="$(awk -v bytes="$RAW_BYTES" -v sec="$seconds" 'BEGIN {printf "%.2f", (sec > 0 ? bytes/1000000/sec : 0)}')"
    rss_mb="$(awk -v bytes="$MEASURE_RSS" 'BEGIN {printf "%.2f", bytes/1000000}')"
    DECODE_SECONDS+=("$seconds")
    DECODE_SPEEDS+=("$speed")
    DECODE_RSS_MB+=("$rss_mb")
    printf "%-7s %-7s %10.2f %12.2f %12.2f\n" "decode" "$round" "$seconds" "$speed" "$rss_mb"

    if [[ "$round" == 1 ]]; then
        diff -qr "$CORPUS" "$dest/$CORPUS_LEAF" >/dev/null
        echo "[Verify] extracted tree matches claw-code / 解壓目錄與 claw-code 完全一致"
    fi
    rm -rf "$dest"
done

ARCHIVE_BYTES="$(stat -f '%z' "$ARCHIVE")"
ARCHIVE_MB="$(awk -v bytes="$ARCHIVE_BYTES" 'BEGIN {printf "%.2f", bytes/1000000}')"
RATIO="$(awk -v archive="$ARCHIVE_BYTES" -v raw="$RAW_BYTES" 'BEGIN {printf "%.2f", archive/raw*100}')"

echo
echo "== Summary / 摘要 =="
echo "ZIP size / ZIP 大小: $ARCHIVE_BYTES bytes ($ARCHIVE_MB MB, $RATIO% of logical input)"
printf "Encode median: %.2f s, %.2f MB/s, peak RSS median %.2f MB\n" \
    "$(median "${ENCODE_SECONDS[@]}")" "$(median "${ENCODE_SPEEDS[@]}")" "$(median "${ENCODE_RSS_MB[@]}")"
printf "Decode median: %.2f s, %.2f MB/s, peak RSS median %.2f MB\n" \
    "$(median "${DECODE_SECONDS[@]}")" "$(median "${DECODE_SPEEDS[@]}")" "$(median "${DECODE_RSS_MB[@]}")"
echo "[PASS] ZIP throughput, RSS, and round-trip verification completed."
echo "[PASS] ZIP 吞吐量、RSS 與往返正確性驗證完成。"
