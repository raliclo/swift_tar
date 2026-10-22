#!/usr/bin/env zsh
# test_unreadable.zsh -- an unreadable directory or file is reported, left out, and exits 1.
# test_unreadable.zsh -- 讀不到的目錄或檔案會被回報、略過，並以 1 結束。
#
#   ./test/test_unreadable.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_unreadable.zsh    # a specific binary
#
# Until 2026-10-22 a `chmod 000` directory read as empty: its header went in, its contents
# vanished, nothing was printed and the exit status was 0. An unreadable file threw after its
# header was written and left a truncated archive. Now both are reported, left out, the rest is
# archived, and the run exits 1 -- what bsdtar does ("Couldn't visit directory: Permission
# denied", "Error exit delayed from previous errors"). Checked for -c, -cz, -r and -u. Needs a
# non-root POSIX user: root reads mode-000 entries, and chmod does not deny access on Windows.
# 2026-10-22 之前，`chmod 000` 的目錄被當成空的：標頭寫進去，內容消失，沒有任何訊息，結束碼 0。
# 讀不到的檔案在標頭寫出之後才擲出，留下一份不完整的封存。現在兩者都會被回報、略過，其餘照常
# 封存，並以 1 結束——與 bsdtar 相同。涵蓋 -c、-cz、-r、-u。需以非 root 的 POSIX 使用者執行：
# root 讀得到 000 的項目，而 Windows 上 chmod 不會拒絕存取。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
ROOT="${script_path:h:h}"
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*)
    echo "SKIP: chmod 000 does not deny access on Windows / Windows 上 chmod 000 不會拒絕存取"
    exit 0 ;;
esac
if [ "$(id -u)" = 0 ]; then
  echo "SKIP: root reads mode-000 entries / root 讀得到 000 的項目"
  exit 0
fi
ST="${ST:-$ROOT/release/swift_tar}"
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
# Restore permissions first, or rm cannot clear the locked directory.
# 先恢復權限，否則 rm 清不掉被鎖住的目錄。
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
cd "$TMP"

mkdir -p src/locked src/ok
echo a > src/ok/a.txt
echo b > src/locked/b.txt
echo c > src/ok/c.txt
echo h > src/ok/h1
ln src/ok/h1 src/ok/h2
lock()   { chmod 000 src/locked src/ok/c.txt src/ok/h1; }
unlock() { chmod 755 src/locked; chmod 644 src/ok/c.txt src/ok/h1; }

# Members, one per line, sorted -- as far as the listing gets. Whether it gets to the end is
# its own check below, so a truncated archive fails that case and does not end the run.
# 成員，一行一個，已排序——列到哪裡就到哪裡。能否列到結尾是下方另一項檢查，所以不完整的封存
# 只讓那一項失敗，不會中途結束整支測試。
members() {
  local rc=0
  "$ST" -tf "$1" > "$TMP/list" 2>/dev/null || rc=$?
  sort "$TMP/list"
}
EXPECTED=$'src/\nsrc/locked/\nsrc/ok/\nsrc/ok/a.txt'

# check <label> <rc> <archive> <stderr file> / 檢查一次執行的結果
check() {
  local label=$1 rc=$2 archive=$3 err=$4 got
  if [ "$rc" = 1 ]; then ok "$label: exit 1"; else bad "$label: exit 1 (got $rc)"; fi
  if grep -q 'src/locked/: cannot read directory' "$err"; then ok "$label: reports the directory"
  else bad "$label: reports the directory ($(head -1 "$err"))"; fi
  if grep -q 'src/ok/c.txt: cannot open' "$err"; then ok "$label: reports the file"
  else bad "$label: reports the file ($(head -1 "$err"))"; fi
  # Readable to the end -- no truncation -- and holding exactly the readable members. h2 is
  # absent too: a hardlink to a file left out would point at nothing.
  # 讀得到結尾——沒有截斷——而且剛好含讀得到的成員。h2 也不在：指向被略過檔案的硬連結會指向空無。
  if "$ST" -tf "$archive" >/dev/null 2>&1; then ok "$label: archive reads to the end"
  else bad "$label: archive reads to the end"; fi
  got=$(members "$archive")
  if [ "$got" = "$EXPECTED" ]; then ok "$label: holds the readable members only"
  else bad "$label: holds the readable members only (got: ${got//$'\n'/ })"; fi
}

lock
rc=0; "$ST" -cf c.tar src 2>c.err || rc=$?
check "-c" "$rc" c.tar c.err

rc=0; "$ST" -czf cz.tgz src 2>cz.err || rc=$?
check "-cz" "$rc" cz.tgz cz.err

# -r onto an archive that already holds a.txt, then -u onto that: each adds nothing new, and
# each must still report and exit 1. / -r 加到已含 a.txt 的封存上，再對它 -u：兩者都不會加入
# 新東西，但都仍須回報並以 1 結束。
unlock; "$ST" -cf r.tar src/ok/a.txt; lock
rc=0; "$ST" -rf r.tar src 2>r.err || rc=$?
if [ "$rc" = 1 ] && grep -q 'src/locked/: cannot read directory' r.err; then ok "-r: reports and exits 1"
else bad "-r: reports and exits 1 (got rc $rc)"; fi
if "$ST" -tf r.tar >/dev/null 2>&1; then ok "-r: archive reads to the end"; else bad "-r: archive reads to the end"; fi
rc=0; "$ST" -uf r.tar src 2>u.err || rc=$?
if [ "$rc" = 1 ] && grep -q 'src/ok/c.txt: cannot open' u.err; then ok "-u: reports and exits 1"
else bad "-u: reports and exits 1 (got rc $rc)"; fi

# An unreadable file named as the operand: an empty but valid archive, exit 1.
# 以讀不到的檔案當操作元：一份空但有效的封存，以 1 結束。
rc=0; "$ST" -cf one.tar src/ok/c.txt 2>one.err || rc=$?
if [ "$rc" = 1 ] && "$ST" -tf one.tar >/dev/null 2>&1 && [ -z "$(members one.tar)" ]; then
  ok "unreadable operand: empty valid archive, exit 1"
else bad "unreadable operand: empty valid archive, exit 1 (rc $rc, members: $(members one.tar))"; fi

# The case as reported: only a directory is unreadable. Before the fix this one exited 0 with
# no message -- the cases above exited 1 only because the unreadable file aborted the run.
# 使用者回報的情況：只有目錄讀不到。修正前這一項以 0 結束且沒有任何訊息——上方各案例會以 1
# 結束，只是因為讀不到的檔案中止了執行。
unlock; chmod 000 src/locked
rc=0; "$ST" -cf dir.tar src 2>dir.err || rc=$?
got=$(members dir.tar)
if [ "$rc" = 1 ] && grep -q 'src/locked/: cannot read directory' dir.err \
   && [ "$got" = $'src/\nsrc/locked/\nsrc/ok/\nsrc/ok/a.txt\nsrc/ok/c.txt\nsrc/ok/h1\nsrc/ok/h2' ]; then
  ok "directory only: reported, exit 1, the rest archived"
else bad "directory only: reported, exit 1, the rest archived (rc $rc, got: ${got//$'\n'/ })"; fi

# Control: everything readable gives exit 0 and every member.
# 對照組：全部讀得到時以 0 結束，且含所有成員。
unlock
rc=0; "$ST" -cf all.tar src 2>all.err || rc=$?
got=$(members all.tar)
if [ "$rc" = 0 ] && [ ! -s all.err ] && [ "$got" = $'src/\nsrc/locked/\nsrc/locked/b.txt\nsrc/ok/\nsrc/ok/a.txt\nsrc/ok/c.txt\nsrc/ok/h1\nsrc/ok/h2' ]; then
  ok "control: all readable, exit 0, every member"
else bad "control: all readable, exit 0, every member (rc $rc, got: ${got//$'\n'/ })"; fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" = 0 ]
