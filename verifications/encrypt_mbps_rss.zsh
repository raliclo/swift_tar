#!/bin/zsh
# =====================================================================
# encrypt_mbps_rss.zsh -- measure the cost of the ChaCha20-Poly1305 layer:
# throughput, peak RSS, and size overhead, both on its own (--encrypt-only /
# --decrypt-only) and layered on top of a codec.
# encrypt_mbps_rss.zsh -- 量測 ChaCha20-Poly1305 加密層的成本：吞吐量、peak RSS
# 與大小額外開銷，分別測「單獨加解密」（--encrypt-only／--decrypt-only）與
# 「疊在 codec 之上」兩種情形。
#
# Usage / 用法：
#   ROUNDS=3 ./encrypt_mbps_rss.zsh ../../claw-code
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

# --help answers before any work starts / --help 在任何工作開始前先回答。
script_path="${0:A}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,23p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

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

# Each phase cleans up after itself, so the peak requirement is roughly three
# corpus-sized files at once. Running out of space does not fail the commands —
# it just makes every timing meaningless — so refuse to start instead.
# 各階段會自行清理，因此尖峰需求約為三份語料大小的檔案。空間不足並不會讓指令
#失敗，只會讓所有計時失去意義，故寧可拒絕開始。
NEED_KB=$(( (RAW_BYTES / 1024) * 3 ))
FREE_KB="$(df -k "$TMP_DIR" | awk 'NR==2 {print $4}')"
if (( FREE_KB < NEED_KB )); then
    awk -v need="$NEED_KB" -v free="$FREE_KB" 'BEGIN {
        printf "[Error] need ~%.1f GB free for temp files, have %.1f GB / 暫存檔約需 %.1f GB，目前僅 %.1f GB\n",
            need/1048576, free/1048576, need/1048576, free/1048576
    }' >&2
    exit 1
fi

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
echo "[Info] rounds / 輪數: $ROUNDS (median reported / 取中位數)"
echo "[Info] key / 金鑰: 64-byte keyfile (no scrypt; see the KDF note below)"
echo

# ---------------------------------------------------------------------
# A) Encryption cost against the same archive with and without --encrypt.
#    加密成本：同一封存在有無 --encrypt 下的對比。
# ---------------------------------------------------------------------
echo "== A) create/extract, plain vs encrypted =="
printf "%-16s %-9s %10s %10s %12s %14s\n" "codec" "mode" "real(s)" "MB/s" "peakRSS(MB)" "archive(bytes)"

run_pair() { # label codec-flags
    # $2 is split into words so a codec can pin its own level. As a single
    # quoted argument the zstd row silently followed swift_tar's default, which
    # moved from 3 to 9 on 2026-08-14 -- the committed MB/s figures would have
    # changed level without the table saying so.
    # $2 會被拆成多個詞，使 codec 得以釘住自身等級。作為單一引號參數時，zstd 那列會
    # 靜默沿用 swift_tar 的預設值，而該預設已於 2026-08-14 由 3 改為 9——入版的 MB/s
    # 數字會在表格毫無說明的情況下換了等級。
    local label="$1"
    local -a flag; flag=(${=2})
    local clear="$TMP_DIR/a_$label.clear" enc="$TMP_DIR/a_$label.enc"
    local -a t_c t_e r_c r_e

    for round in $(seq 1 "$ROUNDS"); do
        if (( ${#flag[@]} )); then
            measure "$SWIFT_TAR_BIN" -c "${flag[@]}" -f "$clear" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        else
            measure "$SWIFT_TAR_BIN" -c -f "$clear" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        fi
        t_c+=("$MEASURE_REAL"); r_c+=("$MEASURE_RSS")
        if (( ${#flag[@]} )); then
            measure "$SWIFT_TAR_BIN" -c "${flag[@]}" --keyfile "$KEYFILE" -f "$enc" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
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
    # Drop this codec's archives before the next one starts. Keeping all three
    # codecs' clear+encrypted copies alive at once needs ~6 GB for a 1.4 GB
    # corpus, and a nearly-full disk makes every figure here meaningless.
    # 在下一個 codec 開始前刪除本 codec 的封存。若三個 codec 的未加密＋加密副本
    # 同時存在，1.4 GB 語料需約 6 GB 空間，而磁碟將滿時所有數字都失去意義。
    rm -rf "$TMP_DIR/x" "$clear" "$enc"
}

run_pair "plain-tar" ""
run_pair "gzip"      "--gzip"
run_pair "zstd"      "--zstd --zstd-level 9"

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
# base.tar is still needed as B2's input; its derived copies are not.
# base.tar 仍是 B2 的輸入而須保留；由它衍生的副本則不需要。
rm -f "$TMP_DIR/base.tar.enc" "$TMP_DIR/base.back.tar"

# ---------------------------------------------------------------------
# B2) How the AEAD scales with -n. Each chunk is sealed independently, so the
#     encryption layer uses the same in-flight budget as the codecs. Measured on
#     --encrypt-only/--decrypt-only over the .tar built above, which is
#     incompressible enough that the AEAD, not a codec, is the work.
#     AEAD 隨 -n 的擴展。各 chunk 獨立封裝，因此加密層與 codec 共用同一組在途
#     預算。以上方建立的 .tar 走 --encrypt-only／--decrypt-only 量測，其內容
#     足夠不可壓縮，主要工作即為 AEAD 而非 codec。
# ---------------------------------------------------------------------
echo
echo "== B2) -n scaling of the encryption layer =="
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
DEFAULT_N=$(( CORES * 2 ))
echo "[Info] cores / 核心數: $CORES, default -n / 預設 -n: $DEFAULT_N (2 x cores, capped at 4 x cores)"
# Settings are interleaved — every round runs the whole sweep — and the best
# time per setting is reported. Running all rounds of one -n before moving to
# the next lets the CPU heat up monotonically, which makes later settings look
# slower than they are; an early version of this script reported a sharp drop at
# high -n that was purely thermal. Interleaving gives each setting the same
# thermal exposure, and best-of picks its coolest sample.
# 各設定交錯執行——每一輪跑完整個 sweep——並回報各設定的最佳時間。若把某個 -n
# 的所有輪次跑完才換下一個，CPU 會單調升溫，使後面的設定看起來較慢；本腳本早期
# 版本就曾回報高 -n 大幅下降，而那純粹是溫度造成的。交錯可讓各設定獲得相同的
# 溫度暴露，取最佳值則挑出其最涼的樣本。
typeset -A best_e best_d rss_e rss_d
SWEEP=(1 2 4 8 16 "$DEFAULT_N")
for n in $SWEEP; do best_e[$n]=999999; best_d[$n]=999999; rss_e[$n]=0; rss_d[$n]=0; done
for round in $(seq 1 "$ROUNDS"); do
    for n in $SWEEP; do
        measure_to_file "$TMP_DIR/scale.enc" "$SWIFT_TAR_BIN" --encrypt-only \
            --keyfile "$KEYFILE" -n "$n" -f "$BASE"
        if (( $(awk -v a="$MEASURE_REAL" -v b="${best_e[$n]}" 'BEGIN{print (a<b)}') )); then
            best_e[$n]="$MEASURE_REAL"; rss_e[$n]="$MEASURE_RSS"
        fi
        measure_to_file "$TMP_DIR/scale.out" "$SWIFT_TAR_BIN" --decrypt-only \
            --keyfile "$KEYFILE" -n "$n" -f "$TMP_DIR/scale.enc"
        if (( $(awk -v a="$MEASURE_REAL" -v b="${best_d[$n]}" 'BEGIN{print (a<b)}') )); then
            best_d[$n]="$MEASURE_REAL"; rss_d[$n]="$MEASURE_RSS"
        fi
        # correctness must hold at every setting, not just the default
        # 每一種設定都必須正確，而不只是預設值
        if ! cmp -s "$BASE" "$TMP_DIR/scale.out"; then
            echo "[Error] -n $n produced a different plaintext / -n $n 解出的明文不一致" >&2
            exit 1
        fi
        # Free this round's copies immediately: two corpus-sized files per -n
        # would otherwise sit on disk for the whole sweep.
        # 立即釋放本輪副本：否則每個 -n 的兩份語料大小檔案會佔用整個 sweep 期間。
        rm -f "$TMP_DIR/scale.enc" "$TMP_DIR/scale.out"
    done
done
printf "%-6s %12s %10s %12s %12s %10s %12s\n" \
    "-n" "enc best(s)" "enc MB/s" "enc RSS(MB)" "dec best(s)" "dec MB/s" "dec RSS(MB)"
for n in $SWEEP; do
    printf "%-6s %12s %10s %12s %12s %10s %12s\n" "$n" \
        "${best_e[$n]}" "$(mbps ${best_e[$n]})" "$(rssmb ${rss_e[$n]})" \
        "${best_d[$n]}" "$(mbps ${best_d[$n]})" "$(rssmb ${rss_d[$n]})"
done
echo "[OK] every -n setting round-trips to identical bytes / 每種 -n 設定皆還原為相同位元組"
rm -f "$BASE"          # last consumer of base.tar / base.tar 的最後一個使用者

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
