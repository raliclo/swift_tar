#!/usr/bin/env zsh
# test_checksum.zsh -- -c writes content checksums by default; --no-checksum omits them.
# test_checksum.zsh -- -c 預設寫入內容校驗碼；--no-checksum 不寫。
#
#   ./test/test_checksum.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_checksum.zsh    # a specific binary
#   ./test/test_checksum.zsh --help
#
# Until 2026-10-07 zstd and lz4 frames carried no checksum, so a chunk corrupted inside a
# raw block decoded "successfully" to wrong bytes and exited 0. Each codec is checked two
# ways: by the flag in its frame/stream header, and by what a corrupted chunk does -- the
# header says the checksum was asked for, the corruption shows it is actually verified.
# gzip, bzip2, lzip and ZIP always carry a CRC; gzip stands in for them to show the flag
# changes nothing there.
#
# 在 2026-10-07 之前，zstd 與 lz4 的 frame 不帶校驗碼，於是原始區塊內損壞的分塊會「成功」
# 解出錯誤的位元組並以 0 結束。每種 codec 以兩種方式檢查：frame／串流標頭中的旗標，以及損壞
# 分塊的結果——標頭說明有要求校驗碼，損壞說明它真的被驗證。gzip、bzip2、lzip 與 ZIP 一律帶
# CRC；以 gzip 為代表，證明此旗標對它們沒有影響。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,24p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE="${script_path:h}"
ROOT="${HERE:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }

# The byte at <offset> masked with <mask>, in decimal; "absent" when the file is missing or
# shorter, so a missing archive can never compare equal to an expected flag value.
# <offset> 處的位元組與 <mask> 取 AND 後的十進位值；檔案不存在或不夠長時為 "absent"，
# 使缺少的封存永遠不會與預期的旗標值相等。
flag_at() {  # <file> <offset> <mask>
  local b=""
  if [ -f "$1" ] && (( $(wc -c < "$1") > $2 )); then
    b=$(od -An -tu1 -j "$2" -N 1 "$1" | tr -d ' \n')
  fi
  if [[ $b == <-> ]]; then print -r -- $(( b & $3 )); else print -r -- absent; fi
}

# Incompressible data, so every codec stores it in raw blocks: corruption there is invisible
# to the format itself and only a checksum can catch it.
# 不可壓縮的資料，使每種 codec 都以原始區塊儲存：在那裡的損壞格式本身看不見，只有校驗碼能抓到。
mkdir -p "$TMP/src"
head -c 1048576 /dev/urandom > "$TMP/src/random.bin"
print -r -- "hello checksum" > "$TMP/src/note.txt"

create() {  # <archive> <flags...> ; status of the create
  local out="$1"; shift
  ( cd "$TMP" && "$ST" -c "$@" -f "$out" src ) >/dev/null 2>&1
}
# Overwrite 64 bytes in the middle of the archive -- inside random.bin's data, in a raw block.
# 覆寫封存中段的 64 位元組——位於 random.bin 的資料內、某個原始區塊中。
corrupt() {  # <in> <out> ; a missing <in> leaves <out> missing, and the decode then fails
  rm -f "$2"
  [ -s "$1" ] || return 0
  cp "$1" "$2"
  local size; size=$(wc -c < "$2" | tr -d ' ')
  head -c 64 /dev/zero | tr '\0' 'Z' | dd of="$2" bs=1 seek="$(( size / 2 ))" conv=notrunc 2>/dev/null
}

# <codec flag> <header offset> <mask> <value with checksum> <value without>
#   zstd: Frame_Header_Descriptor at 4, Content_Checksum_flag is bit 2.
#   lz4:  FLG at 4, C.Checksum is bit 2.
#   xz:   Stream Flags' second byte at 7 is the check ID: 4 = CRC64, 0 = none.
# zstd：位移 4 的 Frame_Header_Descriptor，bit 2 為 Content_Checksum_flag。
# lz4：位移 4 的 FLG，bit 2 為 C.Checksum。
# xz：位移 7 為 Stream Flags 的第二個位元組，即 check ID：4 = CRC64、0 = 無。
check_codec() {
  local flag="$1" off="$2" mask="$3" want_on="$4" want_off="$5"
  local name="${flag#--}"
  local on="$TMP/on.$name" off_a="$TMP/off.$name" dash="$TMP/dash.$name"
  local rc=0

  rc=0; create "$on" "$flag" || rc=$?
  eq "$name: create with the default succeeds" 0 "$rc"
  rc=0; create "$off_a" "$flag" --no-checksum || rc=$?
  eq "$name: create with --no-checksum succeeds" 0 "$rc"
  rc=0; create "$dash" "$flag" -no-checksum || rc=$?
  eq "$name: create with -no-checksum succeeds" 0 "$rc"

  eq "$name: default header asks for a checksum" "$want_on" "$(flag_at "$on" "$off" "$mask")"
  eq "$name: --no-checksum header asks for none" "$want_off" "$(flag_at "$off_a" "$off" "$mask")"
  if [ -s "$off_a" ] && cmp -s "$off_a" "$dash"; then ok "$name: -no-checksum writes what --no-checksum writes"
  else bad "$name: -no-checksum writes what --no-checksum writes"; fi

  local a
  for a in "$on" "$off_a"; do
    rm -rf "$TMP/x"; mkdir -p "$TMP/x"
    rc=0; "$ST" -x -f "$a" -C "$TMP/x" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && diff -r "$TMP/src" "$TMP/x/src" >/dev/null 2>&1; then
      ok "$name: ${a:t:r} round-trips"
    else
      bad "$name: ${a:t:r} round-trips (rc=$rc)"
    fi
  done

  # The status is the assertion, so it is captured rather than left to set -e.
  # 斷言的是狀態本身，所以把它存下來，而不是交給 set -e。
  corrupt "$on" "$TMP/bad.on"
  rc=0; "$ST" --cat -f "$TMP/bad.on" > "$TMP/bad.on.out" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then ok "$name: corruption is reported by default"
  else bad "$name: corruption is reported by default (exit 0)"; fi

  # The other side of the same property: without a checksum the same damage goes through,
  # which shows the default's failure above comes from the checksum and not from the format.
  # 同一性質的另一面：沒有校驗碼時，相同的損壞會通過，這說明上方預設情況的失敗來自校驗碼，
  # 而不是格式本身。
  corrupt "$off_a" "$TMP/bad.off"
  rc=0; "$ST" --cat -f "$TMP/bad.off" > "$TMP/bad.off.out" 2>/dev/null || rc=$?
  eq "$name: with --no-checksum the same corruption goes undetected" 0 "$rc"
}

check_codec --zstd 4 4 4 0
check_codec --lz4  4 4 4 0
check_codec --xz   7 15 4 0

# gzip always carries CRC32: --no-checksum must write the same bytes. The gzip header's
# MTIME field is zero in swift_tar's members, so the two runs are comparable byte for byte.
# gzip 一律帶 CRC32：--no-checksum 必須寫出相同的位元組。swift_tar 的 gzip 成員 MTIME 欄為 0，
# 故兩次執行可逐位元組比較。
rc=0; create "$TMP/g1.tgz" --gzip || rc=$?
eq "gzip: create succeeds" 0 "$rc"
rc=0; create "$TMP/g2.tgz" --gzip --no-checksum || rc=$?
eq "gzip: create with --no-checksum succeeds" 0 "$rc"
if [ -s "$TMP/g1.tgz" ] && cmp -s "$TMP/g1.tgz" "$TMP/g2.tgz"; then ok "gzip: --no-checksum changes nothing"
else bad "gzip: --no-checksum changes nothing"; fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
