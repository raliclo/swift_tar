#!/usr/bin/env zsh
# test_lzfse_cross_group.zsh -- an LZFSE stream whose parallel decode fails part way must
# still come out exactly once, on both the stdin and the file path.
# test_lzfse_cross_group.zsh -- 平行解碼中途失敗的 LZFSE 串流，在 stdin 與檔案兩條路徑上都必須
# 恰好輸出一次。
#
#   ./test/test_lzfse_cross_group.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_lzfse_cross_group.zsh    # a specific binary
#
# The parallel LZFSE decoder (lzfse2) cuts groups where the cumulative raw size reaches a
# multiple of 4 MiB. A stream whose block boundary lands on that multiple, with a match
# reaching back into the previous group, fails in parallel and decodes sequentially. Before
# lzfse2 6e01a03 the stdin path then wrote the whole stream again after the batches already
# written -- `--cat -n 1 -f -` exited 0 with 4 MiB too much -- and the file path rejected the
# valid stream with rc=1. Neither encoder in use produces such a stream, so one is spliced:
#
#   [uncompressed block bvx-, raw size 4 MiB - s] + [swift_tar's other3 stream, first block s]
#
# `-n 1` makes each group its own batch, so the first is written before the second fails.
#
# 平行 LZFSE 解碼器（lzfse2）依累計原始大小在 4 MiB 的倍數處切組。區塊邊界恰好落在該倍數、且
# 下一組有 match 往回參照前一組的串流，平行解會失敗、改走循序。lzfse2 6e01a03 之前，stdin 路徑
# 會在已寫出的批次之後把整份再寫一次——`--cat -n 1 -f -` 以 0 結束、多出 4 MiB——檔案路徑則以
# rc=1 拒絕有效串流。現用的編碼器都不會產生這種串流，所以用拼接造出（如上）。`-n 1` 讓每組自成
# 一批，第一批寫出後第二批才失敗。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,25p' "$script_path" | sed 's/^# \{0,1\}//'
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
size_of() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }

# Repetitive text, so the other3 encoder emits several blocks that refer back to the first.
# 重複的文字，使 other3 編碼器產出數個往回參照第一個區塊的區塊。
mkdir -p "$TMP/src"
: > "$TMP/big"
while (( $(size_of "$TMP/big") < 8388608 )); do cat "$ROOT/swift_tar.swift" >> "$TMP/big"; done
head -c 3000000 "$TMP/big" > "$TMP/src/x"
if ! ( cd "$TMP" && "$ST" -c --other3-optimal -f x.lz src ) >/dev/null 2>&1; then
  echo "SKIP: this build has no other3 encoder (the public build excludes LZFSE)"
  exit 0
fi
"$ST" --cat -f "$TMP/x.lz" > "$TMP/x.tar"

magic=$(head -c 4 "$TMP/x.lz")
s=$(od -A n -t u4 -j 4 -N 4 "$TMP/x.lz" | tr -d ' ')
if [ "$magic" != bvx2 ] || (( s <= 0 || s >= $(size_of "$TMP/x.tar") )); then
  bad "precondition: a first bvx2 block that is not the only one (magic=$magic s=$s)"
  echo "-----------------------------------------"; echo "PASS: $pass  FAIL: $fail"; exit 1
fi

U=$(( 4194304 - s ))
head -c $U "$TMP/big" > "$TMP/u"
hex=$(printf '%08x' $U)
# Uncompressed block header: 'bvx-' + raw size, little-endian 32-bit.
# 未壓縮區塊標頭：'bvx-' + 原始大小（32 位元小端）。
printf "bvx-\\x${hex[7,8]}\\x${hex[5,6]}\\x${hex[3,4]}\\x${hex[1,2]}" > "$TMP/cross.lz"
cat "$TMP/u" "$TMP/x.lz" >> "$TMP/cross.lz"
cat "$TMP/u" "$TMP/x.tar" > "$TMP/expect"
want=$(size_of "$TMP/expect")
# The truncated copy drops the end marker: a genuinely corrupt stream.
# 截斷版拿掉結尾標記：真正損毀的串流。
head -c $(( $(size_of "$TMP/cross.lz") - 64 )) "$TMP/cross.lz" > "$TMP/trunc.lz"

# Statuses are the assertions, so they are captured rather than left to set -e.
# 斷言的是狀態本身，所以把它存下來，而不是交給 set -e。
for n in 1 40; do
  rc=0; "$ST" --cat -n $n -f - < "$TMP/cross.lz" > "$TMP/o" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && cmp -s "$TMP/expect" "$TMP/o"; then ok "valid stream, stdin, -n $n: exact output"
  else bad "valid stream, stdin, -n $n: exact output (rc=$rc size=$(size_of "$TMP/o")/$want)"; fi
  rc=0; "$ST" --cat -n $n -f "$TMP/cross.lz" > "$TMP/o" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && cmp -s "$TMP/expect" "$TMP/o"; then ok "valid stream, file, -n $n: exact output"
  else bad "valid stream, file, -n $n: exact output (rc=$rc size=$(size_of "$TMP/o")/$want)"; fi
done
for n in 1 40; do
  for how in stdin file; do
    rc=0
    if [ $how = stdin ]; then "$ST" --cat -n $n -f - < "$TMP/trunc.lz" > "$TMP/o" 2>/dev/null || rc=$?
    else "$ST" --cat -n $n -f "$TMP/trunc.lz" > "$TMP/o" 2>/dev/null || rc=$?; fi
    sz=$(size_of "$TMP/o")
    if (( rc >= 1 && rc <= 127 && sz <= want )); then ok "truncated, $how, -n $n: fails without overshooting"
    else bad "truncated, $how, -n $n: fails without overshooting (rc=$rc size=$sz/$want)"; fi
  done
done

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
