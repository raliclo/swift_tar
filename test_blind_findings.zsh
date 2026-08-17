#!/usr/bin/env zsh
# test_blind_findings.zsh -- regression tests for the defects found by the
# read_easy blind documentation test (rounds 1-16, 2026-08-18).
# test_blind_findings.zsh -- read_easy 盲測（2026-08-18，round 1-16）所發現
# 缺陷的回歸測試。
#
#   ./test_blind_findings.zsh          # run against release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test_blind_findings.zsh   # or a specific binary
#   ./test_blind_findings.zsh --help
#
# Each case below reproduced a real defect before its fix. Two of them are the
# reason this file uses `timeout` at all: a hang is the failure mode, and a test
# that hangs alongside the program it is testing reports nothing.
# 以下每個案例在修復前都能重現真實缺陷。其中兩項正是本檔必須使用 `timeout` 的
# 原因：失敗形態就是卡死，而與受測程式一起卡死的測試什麼也回報不了。
set -euo pipefail

script_path="${0:A}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,14p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE="${script_path:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
  esac
fi
if [ ! -x "$ST" ]; then
  echo "error: build first — missing swift_tar release binary" >&2
  exit 1
fi

SYS_TAR="${SYS_TAR:-tar}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$desc"; else bad "$desc (want '$want', got '$got')"; fi
}

SRC="$TMP/src"
mkdir -p "$SRC/tree/sub"
printf 'alpha\n' > "$SRC/tree/a.txt"
printf 'bravo\n' > "$SRC/tree/sub/b.txt"
# zstd needs enough redundancy for the level to change the output size.
# zstd 需要足夠的重複性，壓縮等級才會改變輸出大小。
for i in $(seq 1 400); do printf 'the quick brown fox jumps over the lazy dog %s\n' "$i"; done > "$SRC/tree/bulk.txt"

# ---- round 1 / 8: a trailing slash must not double the separator ----
# A trailing slash is what shell tab-completion produces, so this is the common
# spelling, not an exotic one. Unfixed it doubled every stored name, which broke
# name matching rather than merely looking wrong.
# 尾隨斜線正是 shell tab 補全產生的形式，故屬常見寫法而非罕例。未修復時它會使
# 每個檔內名稱加倍，破壞的是名稱比對，而不只是看起來怪。
( cd "$SRC" && "$ST" -c -f "$TMP/slash.tar" tree/ )
( cd "$SRC" && "$SYS_TAR" -cf "$TMP/ref.tar" tree/ )
mine="$("$ST" -t -f "$TMP/slash.tar" | sort | tr '\n' ' ')"
theirs="$("$SYS_TAR" -tf "$TMP/ref.tar" | sort | tr '\n' ' ')"
eq "trailing slash: entry names match system tar" "$theirs" "$mine"

case "$mine" in
  *//*) bad "trailing slash: no doubled separator in stored names" ;;
  *) ok "trailing slash: no doubled separator in stored names" ;;
esac

# --delete must match the name the user types, which is the name on disk --
# not the doubled spelling that only appears in -t output.
# --delete 必須比對使用者鍵入的名稱（即磁碟上的名稱），而非只出現在 -t 輸出中
# 的加倍寫法。
n_before="$("$ST" -t -f "$TMP/slash.tar" | wc -l | tr -d ' ')"
if "$ST" --delete -f "$TMP/slash.tar" tree/a.txt >/dev/null 2>&1; then
  eq "--delete matches a name spelled as on disk" "$((n_before - 1))" \
     "$("$ST" -t -f "$TMP/slash.tar" | wc -l | tr -d ' ')"
else
  bad "--delete matches a name spelled as on disk"
fi

# The listing must be LF, like system tar's. Windows opens the CRT stdout in
# text mode, so print() used to emit CRLF and every line of a diff against a
# bsdtar listing differed by one invisible byte. Counted with tr, never grep:
# MSYS tools read in text mode and strip CR before the regex ever runs.
# 列表必須與系統 tar 一樣是 LF。Windows 的 CRT stdout 預設文字模式，故 print()
# 曾送出 CRLF，使得與 bsdtar 列表做 diff 時每一行都差一個看不見的位元組。以 tr
# 計數而非 grep：MSYS 工具以文字模式讀檔，在正則執行前就已剝除 CR。
eq "-t listing has no CR bytes" "0" "$("$ST" -t -f "$TMP/slash.tar" | tr -dc '\r' | wc -c | tr -d ' ')"
eq "--identify has no CR bytes" "0" "$("$ST" --identify -f "$TMP/slash.tar" | tr -dc '\r' | wc -c | tr -d ' ')"

# -u across two spellings of the same tree must not re-append every member.
# Unfixed, 4 entries became 8 with nothing modified: every member was judged
# absent because the stored name did not match.
# 以兩種拼法對同一棵樹做 -u，不可重新追加所有成員。未修復時在零修改的情況下
# 4 筆會變成 8 筆：所有成員都因檔內名稱不符而被判為不存在。
( cd "$SRC" && "$ST" -c -f "$TMP/upd.tar" tree/ )
before="$("$ST" -t -f "$TMP/upd.tar" | wc -l | tr -d ' ')"
( cd "$SRC" && "$ST" -u -f "$TMP/upd.tar" tree )
after="$("$ST" -t -f "$TMP/upd.tar" | sort -u | wc -l | tr -d ' ')"
eq "-u across spellings does not duplicate members" "$before" "$after"

# ---- round 4: non-terminal stdin must refuse, not block ----
# Both shapes matter and they used to differ: a pipe was caught, `< /dev/null`
# was not, because Windows _isatty() is true for the NUL character device.
# The timeout is the assertion -- without it a regression hangs the suite.
# 兩種形態都重要且曾有差異：管線擋得住，`< /dev/null` 擋不住，因為 Windows 的
# _isatty() 對 NUL 字元裝置為真。timeout 本身就是斷言——沒有它，一旦退化整個
# 測試套件會直接卡死。
rc=0; timeout 20 "$ST" -c --encrypt -f "$TMP/np.enc" -C "$SRC" tree < /dev/null >/dev/null 2>&1 || rc=$?
eq "--encrypt refuses stdin from /dev/null (no hang)" "1" "$rc"
[ ! -e "$TMP/np.enc" ] && ok "--encrypt writes no archive when it refuses" \
  || bad "--encrypt writes no archive when it refuses"

rc=0; printf '' | timeout 20 "$ST" -c --encrypt -f "$TMP/pp.enc" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--encrypt refuses stdin from a pipe (no hang)" "1" "$rc"

# ---- round: inline --opt=value must be read, not ignored ----
# Validation accepts `--flag=value` by comparing only the name before "=", so
# every value reader has to understand it. When they did not, --keyfile=PATH
# fell through to the interactive prompt and hung with no archive.
# 驗證層只比對 "=" 之前的名稱因而接受 `--flag=value`，故每個讀值端都必須認得它。
# 當它們不認得時，--keyfile=PATH 會落到互動式提示並卡死，且毫無產出。
head -c 64 /dev/urandom > "$TMP/k.bin"
rc=0; timeout 20 "$ST" -c --encrypt --keyfile="$TMP/k.bin" -f "$TMP/inline.enc" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--keyfile=PATH is honoured (no prompt, no hang)" "0" "$rc"

mkdir -p "$TMP/out"
if timeout 20 "$ST" -x --keyfile="$TMP/k.bin" -f "$TMP/inline.enc" -C "$TMP/out" >/dev/null 2>&1 \
   && diff -r "$SRC/tree" "$TMP/out/tree" >/dev/null 2>&1; then
  ok "--keyfile=PATH round-trips"
else
  bad "--keyfile=PATH round-trips"
fi

# --zstd-level=N was the silent one: the archive came out byte-identical to the
# default while the command exited 0, so a benchmark recorded the wrong level.
# --zstd-level=N 是靜默的那個：產出的封存與預設完全相同，指令卻以 0 結束，於是
# benchmark 記下的是另一個等級的數字。
"$ST" -c --zstd --zstd-level 19 -f "$TMP/space.tzst" -C "$SRC" tree
"$ST" -c --zstd --zstd-level=19 -f "$TMP/inline.tzst" -C "$SRC" tree
"$ST" -c --zstd            -f "$TMP/default.tzst" -C "$SRC" tree
cmp -s "$TMP/space.tzst" "$TMP/inline.tzst" \
  && ok "--zstd-level=N matches --zstd-level N" \
  || bad "--zstd-level=N matches --zstd-level N"
cmp -s "$TMP/inline.tzst" "$TMP/default.tzst" \
  && bad "--zstd-level=N is not silently ignored" \
  || ok "--zstd-level=N is not silently ignored"

# ---- round 6: one failure status, not two ----
# --zstd-level held the only exit(2) in the program against sixteen exit(1),
# so a caller branching on the value got an answer no other error path gives.
# --zstd-level 曾是全程式唯一的 exit(2)，對比十六處 exit(1)；依離開碼分支的
# 呼叫端會得到其他錯誤路徑都不會給的答案。
rc=0; "$ST" -c --zstd --zstd-level 99 -f "$TMP/bad.tzst" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--zstd-level out of range exits 1" "1" "$rc"
rc=0; "$ST" -c --zstd --zstd-level=99 -f "$TMP/bad.tzst" -C "$SRC" tree >/dev/null 2>&1 || rc=$?
eq "--zstd-level=N out of range exits 1" "1" "$rc"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
