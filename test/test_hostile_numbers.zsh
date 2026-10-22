#!/usr/bin/env zsh
# test_hostile_numbers.zsh -- a header number too large for its use is a format error, not a crash.
# test_hostile_numbers.zsh -- 標頭數值大到無法使用時是格式錯誤，不是崩潰。
#
#   ./test/test_hostile_numbers.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_hostile_numbers.zsh    # a specific binary
#
# A numeric field may be base-256 (first byte 0x80), so a checksum-valid header can carry a
# mode or size near 2^64. Until 2026-10-22 the mode was converted with UInt32(...) and the
# size padded with `size + 511` unchecked, so a 1.5 KB archive made -t, -x, -u and --delete
# trap (rc 132 on Windows and Linux, 133 on macOS) instead of reporting a bad archive. A pax
# `size=` record reached the same arithmetic. Each case here is built byte by byte with a
# correct checksum, and a well-formed control archive proves the builder is right.
# 數值欄位可以是 base-256（首位元組 0x80），所以 checksum 正確的標頭可以帶著接近 2^64 的 mode
# 或 size。2026-10-22 之前，mode 以 UInt32(...) 轉換、size 以未檢查的 `size + 511` 補齊，於是
# 一個 1.5 KB 的封存就讓 -t、-x、-u、--delete trap（Windows 與 Linux 上 rc 132，macOS 上 133），
# 而不是回報封存有誤。pax 的 `size=` 記錄也會走到同一段算式。這裡每一個案例都逐位元組組出、
# checksum 正確，另有一個格式正確的對照組證明組裝方式沒錯。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
ROOT="${script_path:h:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# hex of <text> padded with NUL to <len> bytes / <text> 以 NUL 補到 <len> 位元組的 hex
field() {
  local t=$1 n=$2 h="" i
  for (( i = 1; i <= ${#t}; i++ )); do h+=$(printf '%02x' "'${t[i]}"); done
  while (( ${#h} < n * 2 )); do h+=00; done
  print -rn -- "$h"
}
# One ustar header as hex, checksum filled in. Mode and size are raw hex so that base-256
# values can be given. / 一個 ustar 標頭的 hex，checksum 已填好。mode 與 size 給原始 hex，
# 才能寫 base-256 值。
header() {   # header <name> <mode-hex, 8 bytes> <size-hex, 12 bytes> <typeflag>
  local h ck ckhex="" sum=0 i
  h=$(field "$1" 100)$2$(field 0000000 8)$(field 0000000 8)$3$(field 00000000000 12)
  h+=2020202020202020$(printf '%02x' "'$4")$(field "" 100)7573746172003030$(field "" 247)
  (( ${#h} == 1024 )) || { echo "error: header is $(( ${#h} / 2 )) bytes" >&2; exit 1; }
  for (( i = 1; i <= 1024; i += 2 )); do (( sum += 16#${h[i,i+1]} )); done
  ck=$(printf '%06o' $sum)
  for (( i = 1; i <= 6; i++ )); do ckhex+=$(printf '%02x' "'${ck[i]}"); done
  print -rn -- "${h[1,296]}${ckhex}0020${h[313,-1]}"
}
emit() {     # emit <file> <hex...>: the hex, then two zero blocks / 寫出 hex，再接兩個全零區塊
  local out=$1 hex="${(j::)@[2,-1]}" i
  { for (( i = 1; i <= ${#hex}; i += 2 )); do printf "\\x${hex[i,i+1]}"; done
    head -c 1024 /dev/zero; } > "$out"
}
M644=$(field 0000644 8); S0=$(field 00000000000 12)
HUGE8=80ffffffffffffff; HUGE12=80ffffffffffffffffffffff
REC="29 size=18446744073709551615"$'\n'   # 29 bytes, the whole record / 整筆記錄 29 位元組

emit "$TMP/ok.tar"    "$(header a "$M644" "$S0" 0)"
emit "$TMP/mode.tar"  "$(header a "$HUGE8" "$S0" 0)"
emit "$TMP/xsize.tar" "$(header pax "$M644" "$HUGE12" x)"
emit "$TMP/lsize.tar" "$(header ././@LongLink "$M644" "$HUGE12" L)"
emit "$TMP/fsize.tar" "$(header a "$M644" "$HUGE12" 0)"
emit "$TMP/paxsize.tar" "$(header pax "$M644" "$(field 00000000035 12)" x)$(field "$REC" 512)$(header a "$M644" "$S0" 0)"

# rc 1 with a message is the wanted outcome; >= 128 is a signal. Each mode gets its own copy,
# as -u and --delete write to the archive.
# 想要的結果是 rc 1 並附訊息；>= 128 表示被訊號終止。每種操作各用一份複本，因為 -u 與 --delete
# 會寫入封存。
run() {      # run <archive> <op>
  local a="$TMP/$1.tar" w="$TMP/w_$1_${2//-/}" rc=0
  mkdir -p "$w"; cp "$a" "$w/a.tar"; print x > "$w/m"
  case $2 in
    -t)       "$ST" -tvf "$w/a.tar" ;;
    -x)       "$ST" -xf "$w/a.tar" -C "$w" ;;
    -u)       ( cd "$w" && "$ST" -uf a.tar m ) ;;
    --delete) "$ST" --delete -f "$w/a.tar" zzz ;;
  esac > "$w/out" 2>&1 || rc=$?
  print -r -- "$rc"
}

rc=$(run ok -t)
[ "$rc" = 0 ] && ok "control: a well-formed archive lists, so the builder is right" \
  || bad "control: a well-formed archive lists, so the builder is right (rc $rc: $(tail -1 "$TMP/w_ok_t/out"))"

expect_error() {   # expect_error <archive> <op> <what>
  local rc out
  rc=$(run "$1" "$2"); out="$TMP/w_$1_${2//-/}/out"
  # The message, not just any output: -tv prints its "compression format" line either way.
  # 要看到錯誤訊息，而不只是有輸出：-tv 不論成敗都會印 "compression format" 那一行。
  if [ "$rc" = 1 ] && grep -q 'error' "$out"; then ok "$3: $2 reports an error, rc 1"
  else bad "$3: $2 reports an error, rc 1 (got rc $rc: $(tail -1 "$out"))"; fi
}
# -u and --delete never read the mode, nor a pax `size=` record -- their scanners walk by the
# header's size field alone -- so those two cases are for -t and -x only.
# -u 與 --delete 從不讀 mode，也不讀 pax 的 `size=` 記錄——它們的掃描器只依標頭的 size 欄位
# 前進——所以這兩個案例只測 -t 與 -x。
for op in -t -x; do
  expect_error mode    "$op" "base-256 mode beyond UInt32"
  expect_error paxsize "$op" "pax size=2^64-1"
done
for op in -t -x -u --delete; do
  expect_error xsize   "$op" "base-256 size on a pax header"
  expect_error lsize   "$op" "base-256 size on a GNU long name"
  expect_error fsize   "$op" "base-256 size on a file"
done

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" = 0 ]
