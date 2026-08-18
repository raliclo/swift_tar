#!/bin/zsh
# =====================================================================
# encrypt_mbps_win.zsh -- Windows/MSYS throughput and correctness check for
# swift_tar's ChaCha20-Poly1305 encryption layer.
# encrypt_mbps_win.zsh -- Windows/MSYS 版 swift_tar ChaCha20-Poly1305 加密層
# 吞吐量與正確性驗證。
#
# Usage / 用法:
#   ROUNDS=1 ./encrypt_mbps_win.zsh ../../claw-code
#
# Optional / 選用:
#   VERIFY_TREE=1 ROUNDS=1 ./encrypt_mbps_win.zsh ../../claw-code
#
# MB/s uses the corpus's logical regular-file bytes, not archive size.
# This Windows counterpart intentionally reports throughput only; peak working
# set remains covered by the existing Windows RSS scripts.
# MB/s 以語料內一般檔案 logical bytes 計算，不使用封存大小。本 Windows 對照版
# 只回報吞吐量；peak working set 仍由既有 Windows RSS 腳本覆蓋。
# =====================================================================
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-$ROOT_DIR/release/swift_tar.exe}"
CORPUS="${1:-${ROOT_DIR:h}/claw-code}"
ROUNDS="${ROUNDS:-1}"
VERIFY_TREE="${VERIFY_TREE:-0}"
OUTPUT_TXT="${OUTPUT_TXT:-$SCRIPT_DIR/encrypt_mbps_win_output.txt}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
exec > >(tee "$OUTPUT_TXT") 2>&1

if [[ ! -x "$SWIFT_TAR_BIN" ]]; then
    echo "[Error] swift_tar.exe not found: $SWIFT_TAR_BIN" >&2
    echo "        Build first with compile_tar-win.bat." >&2
    exit 1
fi
if [[ ! -d "$CORPUS" ]]; then
    echo "[Error] corpus not found: $CORPUS" >&2
    exit 1
fi
if ! [[ "$ROUNDS" =~ '^[1-9][0-9]*$' ]]; then
    echo "[Error] ROUNDS must be a positive integer / ROUNDS 必須為正整數" >&2
    exit 1
fi

# zsh's own zstat, not the external stat. The Windows zsh port ships a `stat`
# that reports itself as GNU coreutils 8.32 and returns 0 for --version, yet
# cannot open a /c/... path at all:
#
#   stat -c '%s' /c/Windows/System32/tar.exe
#   -> cannot stat '/c/Windows/System32/tar.exe': No such file or directory
#
# so the old probe passed and the script still failed on its first size lookup.
# The probe asked "is this GNU stat?" when the thing that mattered was "can it
# open this file?". zstat is a shell builtin, needs no PATH lookup, and works on
# both path styles. parallel_extract_correctness.zsh already does it this way.
#
# 使用 zsh 自身的 zstat，而非外部 stat。Windows 的 zsh 移植版自帶一支 `stat`，
# 它自稱 GNU coreutils 8.32、`--version` 回傳 0，卻完全開不了 /c/... 路徑（如上），
# 因此舊的探測通過了，腳本仍在第一次取檔案大小時失敗。該探測問的是「這是不是 GNU
# stat」，但真正該問的是「它開不開得了這個檔」。zstat 是 shell builtin，不做 PATH
# 查找，且兩種路徑寫法皆可用。parallel_extract_correctness.zsh 已是這個做法。
zmodload zsh/stat 2>/dev/null || {
    print -ru2 -- "[Error] zsh/stat module unavailable"; exit 1
}
stat_size() { zstat +size "$1" }

elapsed_seconds() {
    local start_ns="$1"
    local end_ns="$2"
    awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f", (e - s) / 1000000000 }'
}

measure() {
    local start_ns end_ns rc
    start_ns="$(date +%s%N)"
    "$@" >/dev/null
    rc=$?
    end_ns="$(date +%s%N)"
    MEASURE_REAL="$(elapsed_seconds "$start_ns" "$end_ns")"
    return "$rc"
}

measure_to_file() {
    local dest="$1"
    shift
    local start_ns end_ns rc
    start_ns="$(date +%s%N)"
    "$@" > "$dest"
    rc=$?
    end_ns="$(date +%s%N)"
    MEASURE_REAL="$(elapsed_seconds "$start_ns" "$end_ns")"
    return "$rc"
}

median() {
    printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END {if (NR%2) print v[(NR+1)/2]; else printf "%.6f\n", (v[NR/2]+v[NR/2+1])/2}'
}

mbps() {
    awk -v bytes="$RAW_BYTES" -v sec="$1" 'BEGIN {printf "%.2f", (sec > 0 ? bytes / 1000000 / sec : 0)}'
}

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
must_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        bad "$desc"
    else
        ok "$desc"
    fi
}

CORPUS="${CORPUS:A}"
CORPUS_PARENT="${CORPUS:h}"
CORPUS_LEAF="${CORPUS:t}"

RAW_BYTES=0
FILE_COUNT=0
for file in "$CORPUS"/**/*(.DN); do
    RAW_BYTES=$(( RAW_BYTES + $(stat_size "$file") ))
    FILE_COUNT=$(( FILE_COUNT + 1 ))
done
RAW_MB="$(awk -v bytes="$RAW_BYTES" 'BEGIN {printf "%.2f", bytes / 1000000}')"

KEYFILE="$TMP_DIR/key.bin"
WRONG_KEYFILE="$TMP_DIR/wrong-key.bin"
head -c 64 /dev/urandom > "$KEYFILE"
head -c 64 /dev/urandom > "$WRONG_KEYFILE"

NEED_KB=$(( (RAW_BYTES / 1024) * 3 ))
FREE_KB="$(df -k "$TMP_DIR" | awk 'NR==2 {print $4}')"
if (( FREE_KB < NEED_KB )); then
    awk -v need="$NEED_KB" -v free="$FREE_KB" 'BEGIN {
        printf "[Error] need ~%.1f GB free for temp files, have %.1f GB\n",
            need / 1048576, free / 1048576
    }' >&2
    exit 1
fi

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
echo "[Info] host / 主機: $(uname -a)"
VERSION_LINE="$("$SWIFT_TAR_BIN" --version 2>&1 | tr -d '\r')"
echo "[Info] swift_tar: $SWIFT_TAR_BIN ($VERSION_LINE)"
echo "[Info] corpus / 語料: $CORPUS"
echo "[Info] regular files / 一般檔案: $FILE_COUNT"
echo "[Info] logical input / 邏輯輸入: $RAW_BYTES bytes ($RAW_MB MB)"
echo "[Info] rounds / 輪數: $ROUNDS (median reported / 取中位數)"
echo "[Info] verify tree / 完整 tree 比對: $VERIFY_TREE (default 0 for Windows throughput / Windows 吞吐量預設關閉)"
echo "[Info] key / 金鑰: 64-byte keyfile (no scrypt / 不含 scrypt KDF)"
echo

echo "== crypto self-test =="
"$SWIFT_TAR_BIN" --crypto-selftest
echo

echo "== A) create/extract, plain vs encrypted =="
printf "%-16s %-9s %10s %10s %14s\n" "codec" "mode" "real(s)" "MB/s" "archive(bytes)"

run_pair() {
    # $2 is split into words so a codec can pin its own level; see the same
    # change in encrypt_mbps_rss.zsh. swift_tar's default zstd level moved from 3
    # to 9 on 2026-08-14, so a bare --zstd silently changed what this measures.
    # $2 會被拆成多個詞，使 codec 得以釘住自身等級；同樣的改動見 encrypt_mbps_rss.zsh。
    # swift_tar 的 zstd 預設等級已於 2026-08-14 由 3 改為 9，故裸 --zstd 會靜默改變本
    # 腳本所量測的對象。
    local label="$1"
    local -a flag; flag=(${=2})
    local clear="$TMP_DIR/a_$label.clear"
    local enc="$TMP_DIR/a_$label.enc"
    local -a create_t enc_t extract_t dec_t
    local round

    for round in $(seq 1 "$ROUNDS"); do
        if (( ${#flag[@]} )); then
            measure "$SWIFT_TAR_BIN" -c "${flag[@]}" -f "$clear" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        else
            measure "$SWIFT_TAR_BIN" -c -f "$clear" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        fi
        create_t+=("$MEASURE_REAL")

        if (( ${#flag[@]} )); then
            measure "$SWIFT_TAR_BIN" -c "${flag[@]}" --keyfile "$KEYFILE" -f "$enc" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        else
            measure "$SWIFT_TAR_BIN" -c --keyfile "$KEYFILE" -f "$enc" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
        fi
        enc_t+=("$MEASURE_REAL")
    done

    local create_m enc_m
    create_m="$(median $create_t)"
    enc_m="$(median $enc_t)"
    printf "%-16s %-9s %10s %10s %14s\n" "$label" "create" "$create_m" "$(mbps "$create_m")" "$(stat_size "$clear")"
    printf "%-16s %-9s %10s %10s %14s\n" "" "create+enc" "$enc_m" "$(mbps "$enc_m")" "$(stat_size "$enc")"

    for round in $(seq 1 "$ROUNDS"); do
        rm -rf "$TMP_DIR/x-clear" "$TMP_DIR/x-enc"
        mkdir -p "$TMP_DIR/x-clear" "$TMP_DIR/x-enc"

        measure "$SWIFT_TAR_BIN" -x -f "$clear" -C "$TMP_DIR/x-clear"
        extract_t+=("$MEASURE_REAL")
        measure "$SWIFT_TAR_BIN" -x --keyfile "$KEYFILE" -f "$enc" -C "$TMP_DIR/x-enc"
        dec_t+=("$MEASURE_REAL")
    done

    local extract_m dec_m
    extract_m="$(median $extract_t)"
    dec_m="$(median $dec_t)"
    printf "%-16s %-9s %10s %10s %14s\n" "" "extract" "$extract_m" "$(mbps "$extract_m")" "-"
    printf "%-16s %-9s %10s %10s %14s\n" "" "extr+dec" "$dec_m" "$(mbps "$dec_m")" "-"

    local clear_count enc_count
    clear_count="$(find "$TMP_DIR/x-clear/$CORPUS_LEAF" -type f | wc -l | tr -d ' ')"
    enc_count="$(find "$TMP_DIR/x-enc/$CORPUS_LEAF" -type f | wc -l | tr -d ' ')"
    if [[ "$clear_count" == "$FILE_COUNT" && "$enc_count" == "$FILE_COUNT" ]]; then
        ok "$label extracted file count matches source"
    else
        bad "$label extracted file count mismatch"
    fi

    if [[ "$VERIFY_TREE" == "1" ]]; then
        if diff -r "$CORPUS" "$TMP_DIR/x-clear/$CORPUS_LEAF" >/dev/null 2>&1 \
            && diff -r "$CORPUS" "$TMP_DIR/x-enc/$CORPUS_LEAF" >/dev/null 2>&1; then
            ok "$label full tree diff matches source"
        else
            bad "$label full tree diff differs from source"
        fi
    fi

    rm -rf "$TMP_DIR/x-clear" "$TMP_DIR/x-enc" "$clear" "$enc"
}

run_pair "plain-tar" ""
run_pair "gzip" "--gzip"
run_pair "zstd" "--zstd --zstd-level 9"

echo
echo "== B) --encrypt-only / --decrypt-only on an existing .tar =="
BASE="$TMP_DIR/base.tar"
"$SWIFT_TAR_BIN" -c -f "$BASE" -C "$CORPUS_PARENT" "$CORPUS_LEAF"
BASE_BYTES="$(stat_size "$BASE")"
printf "%-16s %10s %10s %14s\n" "phase" "real(s)" "MB/s" "output(bytes)"

typeset -a enc_only_t dec_only_t
for round in $(seq 1 "$ROUNDS"); do
    measure_to_file "$TMP_DIR/base.tar.enc" "$SWIFT_TAR_BIN" --encrypt-only --keyfile "$KEYFILE" -f "$BASE"
    enc_only_t+=("$MEASURE_REAL")
    measure_to_file "$TMP_DIR/base.back.tar" "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$KEYFILE" -f "$TMP_DIR/base.tar.enc"
    dec_only_t+=("$MEASURE_REAL")
    cmp -s "$BASE" "$TMP_DIR/base.back.tar" \
        && ok "encrypt-only/decrypt-only byte-for-byte round $round" \
        || bad "encrypt-only/decrypt-only byte-for-byte round $round"
done

enc_only_m="$(median $enc_only_t)"
dec_only_m="$(median $dec_only_t)"
printf "%-16s %10s %10s %14s\n" "encrypt-only" "$enc_only_m" "$(mbps "$enc_only_m")" "$(stat_size "$TMP_DIR/base.tar.enc")"
printf "%-16s %10s %10s %14s\n" "decrypt-only" "$dec_only_m" "$(mbps "$dec_only_m")" "$(stat_size "$TMP_DIR/base.back.tar")"

ENC_BYTES="$(stat_size "$TMP_DIR/base.tar.enc")"
awk -v raw="$BASE_BYTES" -v enc="$ENC_BYTES" 'BEGIN {
    over = enc - raw
    printf "[Info] size overhead / 大小開銷: %d bytes (%.4f%%), = 48B header + 21B per 4 MiB chunk\n",
        over, (raw > 0 ? over * 100.0 / raw : 0)
}'

must_fail "wrong key is rejected" \
    "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$WRONG_KEYFILE" -f "$TMP_DIR/base.tar.enc"

cp "$TMP_DIR/base.tar.enc" "$TMP_DIR/tamper.enc"
printf 'X' | dd of="$TMP_DIR/tamper.enc" bs=1 seek=60 count=1 conv=notrunc >/dev/null 2>&1
must_fail "tampered ciphertext is rejected" \
    "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$KEYFILE" -f "$TMP_DIR/tamper.enc"

echo
echo "SUMMARY: PASS=$pass FAIL=$fail"
echo "[Done] output / 輸出: $OUTPUT_TXT"
[[ "$fail" -eq 0 ]]
