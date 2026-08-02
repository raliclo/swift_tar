#!/bin/zsh
# =====================================================================
# encrypt_mbps_rss.sh -- measure the cost of the ChaCha20-Poly1305 layer:
# throughput, peak RSS, and size overhead, both on its own (--encrypt-only /
# --decrypt-only) and layered on top of a codec.
# encrypt_mbps_rss.sh -- 量測 ChaCha20-Poly1305 加密層的成本：吞吐量、peak RSS
# 與大小額外開銷，分別測「單獨加解密」（--encrypt-only／--decrypt-only）與
# 「疊在 codec 之上」兩種情形。
#
# Usage / 用法：
#   ROUNDS=3 ./encrypt_mbps_rss.sh ../../claw-code
#
# The keyfile path is used throughout so the runs are non-interactive. Because
# --keyfile skips the scrypt KDF, these numbers measure the AEAD itself; the
# one-off scrypt cost of a passphrase is measured separately at the end.
# 全程使用 keyfile 以維持非互動。由於 --keyfile 不走 scrypt KDF，這些數字量的是
# AEAD 本身；密語一次性的 scrypt 成本另於結尾單獨回報。
#
# MB/s uses the corpus's logical regular-file bytes, not the archive size. RSS
# is the maximum resident set size of the swift_tar process itself.
# MB/s 以語料內一般檔案的 logical bytes 計算，不使用封存大小；RSS 是 swift_tar
# 程序本身的 maximum resident set size。
# =====================================================================
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-${SCRIPT_DIR:h}/release/swift_tar}"
CORPUS="${1:-${SCRIPT_DIR:h:h}/claw-code}"
ROUNDS="${ROUNDS:-3}"
OUTPUT_TXT="$SCRIPT_DIR/encrypt_mbps_rss_output.txt"
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
if ! command -v swiftc >/dev/null 2>&1; then
    echo "[Error] swiftc is required for the KDF measurement / KDF 量測需要 swiftc" >&2
    exit 1
fi

CORPUS="${CORPUS:A}"
CORPUS_PARENT="${CORPUS:h}"
CORPUS_LEAF="${CORPUS:t}"
RAW_BYTES="$(find "$CORPUS" -type f -exec stat -f '%z' {} + | awk '{sum += $1} END {printf "%.0f", sum}')"
FILE_COUNT="$(find "$CORPUS" -type f | wc -l | tr -d ' ')"
RAW_MB="$(awk -v bytes="$RAW_BYTES" 'BEGIN {printf "%.2f", bytes / 1000000}')"

KEYFILE="$TMP_DIR/key.bin"
head -c 64 /dev/urandom > "$KEYFILE"

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

# measure a command whose output is a file written via stdout redirection
# 量測以 stdout 重導向寫檔的指令
measure_to_file() {
    local dest="$1"; shift
    local log="$TMP_DIR/time-$RANDOM.log"
    if ! /usr/bin/time -l "$@" >"$dest" 2>"$log"; then
        cat "$log" >&2
        return 1
    fi
    MEASURE_REAL="$(awk '$2 == "real" {print $1; exit}' "$log")"
    MEASURE_RSS="$(awk '/maximum resident set size/ {print $1; exit}' "$log")"
}

median() {
    printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END {if (NR%2) print v[(NR+1)/2]; else printf "%.6f\n", (v[NR/2]+v[NR/2+1])/2}'
}
mbps() { awk -v bytes="$RAW_BYTES" -v sec="$1" 'BEGIN {printf "%.2f", (sec > 0 ? bytes/1000000/sec : 0)}'; }
rssmb() { awk -v bytes="$1" 'BEGIN {printf "%.2f", bytes/1000000}'; }

echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] machine / 機器: $(uname -m), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
echo "[Info] swift_tar: $SWIFT_TAR_BIN ($("$SWIFT_TAR_BIN" --version))"
echo "[Info] corpus / 語料: $CORPUS"
echo "[Info] regular files / 一般檔案: $FILE_COUNT"
echo "[Info] logical input / 邏輯輸入: $RAW_BYTES bytes ($RAW_MB MB)"
echo "[Info] rounds / 輪數: $ROUNDS (median reported / 取中位數)"
echo "[Info] key / 金鑰: 64-byte keyfile (no scrypt; see the KDF note below)"
echo

# ---------------------------------------------------------------------
# A) Encryption cost against the same archive with and without --encrypt.
#    加密成本：同一封存在有無 --encrypt 下的對比。
# ---------------------------------------------------------------------
echo "== A) create/extract, plain vs encrypted =="
printf "%-16s %-9s %10s %10s %12s %14s\n" "codec" "mode" "real(s)" "MB/s" "peakRSS(MB)" "archive(bytes)"

run_pair() { # label codec-flag
    local label="$1" flag="$2"
    local clear="$TMP_DIR/a_$label.clear" enc="$TMP_DIR/a_$label.enc"
    local -a t_c t_e r_c r_e

    for round in $(seq 1 "$ROUNDS"); do
        if [[ -n "$flag" ]]; then
            measure "$SWIFT_TAR_BIN" -c "$flag" -f "$clear" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        else
            measure "$SWIFT_TAR_BIN" -c -f "$clear" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        fi
        t_c+=("$MEASURE_REAL"); r_c+=("$MEASURE_RSS")
        if [[ -n "$flag" ]]; then
            measure "$SWIFT_TAR_BIN" -c "$flag" --keyfile "$KEYFILE" -f "$enc" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        else
            measure "$SWIFT_TAR_BIN" --keyfile "$KEYFILE" -c -f "$enc" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        fi
        t_e+=("$MEASURE_REAL"); r_e+=("$MEASURE_RSS")
    done
    local mc="$(median $t_c)" me="$(median $t_e)"
    printf "%-16s %-9s %10s %10s %12s %14s\n" "$label" "create" "$mc" "$(mbps $mc)" \
        "$(rssmb $(median $r_c))" "$(stat -f '%z' "$clear")"
    printf "%-16s %-9s %10s %10s %12s %14s\n" "" "create+enc" "$me" "$(mbps $me)" \
        "$(rssmb $(median $r_e))" "$(stat -f '%z' "$enc")"

    # extraction side / 解出端
    local -a x_c x_e xr_c xr_e
    for round in $(seq 1 "$ROUNDS"); do
        rm -rf "$TMP_DIR/x"; mkdir -p "$TMP_DIR/x"
        measure "$SWIFT_TAR_BIN" -x -f "$clear" -C "$TMP_DIR/x"
        x_c+=("$MEASURE_REAL"); xr_c+=("$MEASURE_RSS")
        rm -rf "$TMP_DIR/x"; mkdir -p "$TMP_DIR/x"
        measure "$SWIFT_TAR_BIN" -x --keyfile "$KEYFILE" -f "$enc" -C "$TMP_DIR/x"
        x_e+=("$MEASURE_REAL"); xr_e+=("$MEASURE_RSS")
    done
    local xc="$(median $x_c)" xe="$(median $x_e)"
    printf "%-16s %-9s %10s %10s %12s %14s\n" "" "extract" "$xc" "$(mbps $xc)" "$(rssmb $(median $xr_c))" "-"
    printf "%-16s %-9s %10s %10s %12s %14s\n" "" "extr+dec" "$xe" "$(mbps $xe)" "$(rssmb $(median $xr_e))" "-"
    rm -rf "$TMP_DIR/x"
}

run_pair "plain-tar" ""
run_pair "gzip"      "--gzip"
run_pair "zstd"      "--zstd"

# ---------------------------------------------------------------------
# B) The encryption layer on its own, over an existing archive.
#    加密層單獨作用於既有封存。
# ---------------------------------------------------------------------
echo
echo "== B) --encrypt-only / --decrypt-only on an existing .tar =="
BASE="$TMP_DIR/base.tar"
"$SWIFT_TAR_BIN" -c -f "$BASE" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
BASE_BYTES="$(stat -f '%z' "$BASE")"
printf "%-16s %10s %10s %12s %14s\n" "phase" "real(s)" "MB/s" "peakRSS(MB)" "output(bytes)"

typeset -a eo_t eo_r do_t do_r
for round in $(seq 1 "$ROUNDS"); do
    measure_to_file "$TMP_DIR/base.tar.enc" "$SWIFT_TAR_BIN" --encrypt-only --keyfile "$KEYFILE" -f "$BASE"
    eo_t+=("$MEASURE_REAL"); eo_r+=("$MEASURE_RSS")
    measure_to_file "$TMP_DIR/base.back.tar" "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$KEYFILE" -f "$TMP_DIR/base.tar.enc"
    do_t+=("$MEASURE_REAL"); do_r+=("$MEASURE_RSS")
done
et="$(median $eo_t)"; dt="$(median $do_t)"
printf "%-16s %10s %10s %12s %14s\n" "encrypt-only" "$et" "$(mbps $et)" "$(rssmb $(median $eo_r))" "$(stat -f '%z' "$TMP_DIR/base.tar.enc")"
printf "%-16s %10s %10s %12s %14s\n" "decrypt-only" "$dt" "$(mbps $dt)" "$(rssmb $(median $do_r))" "$(stat -f '%z' "$TMP_DIR/base.back.tar")"

if cmp -s "$BASE" "$TMP_DIR/base.back.tar"; then
    echo "[OK] decrypt-only output is byte-identical to the original / 與原檔位元組一致"
else
    echo "[Error] decrypt-only output differs from the original / 與原檔不一致" >&2
    exit 1
fi

ENC_BYTES="$(stat -f '%z' "$TMP_DIR/base.tar.enc")"
awk -v raw="$BASE_BYTES" -v enc="$ENC_BYTES" 'BEGIN {
    over = enc - raw
    printf "[Info] size overhead / 大小開銷: %d bytes (%.4f%%), = 48B header + 21B per 4 MiB chunk\n",
        over, (raw > 0 ? over * 100.0 / raw : 0)
}'

# ---------------------------------------------------------------------
# C) Measure the one-off scrypt cost that --keyfile skips. A tiny helper is
#    compiled against the same crypto.swift and encrypts an empty stream, so the
#    difference between modes isolates key derivation from payload processing.
#    量測 --keyfile 略過的一次性 scrypt 成本。小型 helper 直接連結同一份
#    crypto.swift 並加密空串流，兩種模式的差異可排除 payload 處理成本。
# ---------------------------------------------------------------------
echo
echo "== C) passphrase KDF (scrypt N=2^15, r=8, p=1) =="
KDF_BENCH="$TMP_DIR/kdf_benchmark"
swiftc -O "$SCRIPT_DIR/../crypto.swift" "$SCRIPT_DIR/kdf_benchmark.swift" -o "$KDF_BENCH"
typeset -a kdf_key_t kdf_key_r kdf_pass_t kdf_pass_r
for round in $(seq 1 "$ROUNDS"); do
    measure "$KDF_BENCH" keyfile
    kdf_key_t+=("$MEASURE_REAL"); kdf_key_r+=("$MEASURE_RSS")
    measure "$KDF_BENCH" passphrase
    kdf_pass_t+=("$MEASURE_REAL"); kdf_pass_r+=("$MEASURE_RSS")
done
key_t="$(median $kdf_key_t)"; pass_t="$(median $kdf_pass_t)"
key_r="$(rssmb $(median $kdf_key_r))"; pass_r="$(rssmb $(median $kdf_pass_r))"
printf "%-16s %10s %12s\n" "mode" "real(s)" "peakRSS(MB)"
printf "%-16s %10s %12s\n" "keyfile" "$key_t" "$key_r"
printf "%-16s %10s %12s\n" "passphrase" "$pass_t" "$pass_r"
awk -v pass="$pass_t" -v key="$key_t" 'BEGIN {
    printf "[Info] measured scrypt time delta / 實測 scrypt 時間差: %.3f s per derivation\n", pass - key
}'
echo "[Info] --encrypt pays this once per archive on create and read."
echo "       --encrypt 每個封存於建立與讀取時各支付一次此成本。"

echo
echo "[Done] output / 輸出: $OUTPUT_TXT"
