#!/usr/bin/env zsh
# test_create_readahead.zsh -- `-c` reads the next small files in the background (ReadAhead);
# the archive must still hold every file's own bytes, in the walk's order, and never hang.
# test_create_readahead.zsh -- `-c` 會在背景預讀接下來的小檔（ReadAhead）；封存仍必須保有每個
# 檔案自己的位元組、依走訪順序排列，而且絕不能卡住。
#
#   ./test/test_create_readahead.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_create_readahead.zsh    # a specific binary
#
# What would go wrong if the prefetch stack fell out of step with the walk is not a crash:
# a file's header would be followed by another file's bytes of the same size, or by bytes
# read before the file was replaced. So every case extracts and compares contents, and the
# tree is built so that many files share a size -- a wrong pairing would not be caught by
# a size check alone. Cases that end an add() early (excluded, symlink, hardlink, FIFO,
# --update) sit between ordinary files, since each one is a chance for the stack to slip.
#
# 若預讀堆疊與走訪脫節，出錯的方式不是當掉，而是某個檔案的標頭後面接了另一個同大小檔案的
# 位元組，或檔案被替換前讀到的位元組。所以每一項都解出並比對內容，而且樹中刻意讓許多檔案
# 大小相同——錯配單靠大小檢查是抓不到的。會讓 add() 提前結束的情形（排除、symlink、硬連結、
# FIFO、--update）都夾在一般檔案之間，因為每一個都是堆疊錯位的機會。
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

# Contents of every regular file, by path. / 依路徑列出每個一般檔案的內容雜湊。
manifest() { ( cd -q "$1" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 ) | shasum -a 256 | cut -c1-16; }

# run_limited <label> <-c|-u> <archive> <args...> ; runs swift_tar in $TMP with a 60 s limit,
# so a read that blocks (a FIFO) fails the test instead of hanging it. `exec` makes $! the
# swift_tar process itself, so the kill reaches it rather than leaving it orphaned. A failure
# is recorded and the run goes on (return 0), so one hang does not hide the other cases.
# 在 $TMP 中執行 swift_tar，上限 60 秒，使會卡住的讀取（FIFO）讓測試失敗而不是讓它卡住。
# `exec` 使 $! 就是 swift_tar 本身，kill 才會打到它，而不是留下孤兒程序。失敗會被記下並繼續
# 執行（return 0），一次卡住不會蓋掉其餘各項。
run_limited() {
  local label=$1 mode=$2 arc=$3; shift 3
  ( cd -q "$TMP" && exec "$ST" $mode "$@" -f "$arc" ) >/dev/null 2>"$arc.err" &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    # `|| true` on purpose: wait returns 137 for the process just killed, and under set -e
    # that ended this whole script with 137 and no output.
    # 刻意使用 `|| true`：對剛被結束的程序，wait 會回傳 137，在 set -e 下那會讓整支腳本以
    # 137 結束、沒有任何輸出。
    (( waited >= 600 )) && { kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null || true; bad "$label: finished within 60 s (killed)"; return 0; }
    sleep 0.1; waited=$((waited + 1))
  done
  local rc=0; wait $pid || rc=$?
  (( rc == 0 )) && ok "$label: $mode exits 0" || { bad "$label: $mode exits 0 (got $rc: $(head -c 200 "$arc.err"))"; return 0; }
}
create_ok() { local label=$1 arc=$2; shift 2; run_limited "$label" -c "$arc" "$@"; }

# ---- the tree / 測試樹 ----
SRC="$TMP/src"
mkdir -p "$SRC"
# 40 directories x 30 files, all 4096 bytes: a misplaced payload keeps the size and changes
# the content. Deep nesting so children are pushed while siblings are still pending.
# 40 個目錄 × 30 個檔案，全部 4096 位元組：錯置的內容大小不變、內容改變。巢狀較深，使子項目
# 在兄弟項目仍待處理時被推入堆疊。
for d in {1..40}; do
  p="$SRC/d$d/sub/subsub"; mkdir -p "$p"
  for f in {1..30}; do head -c 4096 /dev/urandom > "$SRC/d$d/f$f.bin"; done
  for f in {1..5}; do head -c 4096 /dev/urandom > "$p/g$f.bin"; done
done
# Boundaries around ReadAhead.fileMax (1 MiB), empty files. / ReadAhead.fileMax（1 MiB）前後與空檔。
head -c 1048575 /dev/urandom > "$SRC/d1/just_under.bin"
head -c 1048576 /dev/urandom > "$SRC/d1/exactly.bin"
head -c 1048577 /dev/urandom > "$SRC/d1/just_over.bin"
head -c 9000000 /dev/urandom > "$SRC/d2/large.bin"
: > "$SRC/d3/empty1"; : > "$SRC/d3/empty2"
# Entries that end add() early, between ordinary files. / 讓 add() 提前結束的項目，夾在一般檔案之間。
ln -s f1.bin "$SRC/d4/f10_link"
ln -s /nonexistent "$SRC/d4/f20_dangling"
ln "$SRC/d5/f1.bin" "$SRC/d5/f15_hard"
mkfifo "$SRC/d6/f12_fifo"
print -r -- skipme > "$SRC/d7/f13.skip"

WANT=$(manifest "$SRC")

create_ok "tree" "$TMP/a.tar" src
mkdir -p "$TMP/x1"; "$ST" -x -f "$TMP/a.tar" -C "$TMP/x1" >/dev/null 2>&1 || true
[ "$(manifest "$TMP/x1/src")" = "$WANT" ] && ok "tree: every file holds its own bytes" \
  || bad "tree: every file holds its own bytes"
[ -L "$TMP/x1/src/d4/f10_link" ] && ok "tree: a symlink stays a symlink" || bad "tree: a symlink stays a symlink"
[ -p "$TMP/x1/src/d6/f12_fifo" ] && ok "tree: a FIFO is archived as a FIFO, without blocking" \
  || bad "tree: a FIFO is archived as a FIFO, without blocking"

# The same archive twice: the order and bytes do not depend on which reads finished first.
# 同一封存建兩次：順序與位元組不取決於哪個讀取先完成。
create_ok "repeat" "$TMP/b.tar" src
cmp -s "$TMP/a.tar" "$TMP/b.tar" && ok "repeat: two runs write identical archives" \
  || bad "repeat: two runs write identical archives"

# With a codec: the compressed stream decodes to the same tar. / 帶 codec：壓縮串流解開後是同一個 tar。
create_ok "zstd" "$TMP/c.tar.zst" --zstd src
"$ST" --cat -f "$TMP/c.tar.zst" 2>/dev/null | cmp -s - "$TMP/a.tar" && ok "zstd: decodes to the same tar" \
  || bad "zstd: decodes to the same tar"

# --exclude between ordinary files. / 夾在一般檔案之間的 --exclude。
create_ok "exclude" "$TMP/e.tar" --exclude '*.skip' src
mkdir -p "$TMP/x2"; "$ST" -x -f "$TMP/e.tar" -C "$TMP/x2" >/dev/null 2>&1 || true
rm -f "$TMP/x2/src/d7/f13.skip" 2>/dev/null; cp -R "$SRC" "$TMP/srcx"; rm -f "$TMP/srcx/d7/f13.skip"
[ "$(manifest "$TMP/x2/src")" = "$(manifest "$TMP/srcx")" ] \
  && ok "exclude: the rest still hold their own bytes" || bad "exclude: the rest still hold their own bytes"
[ ! -e "$TMP/x2/src/d7/f13.skip" ] && ok "exclude: the excluded file is absent" \
  || bad "exclude: the excluded file is absent"

# Many operands, the shape of a multissh shard: each file named on the command line.
# 大量運算元，即 multissh 分片的形狀：每個檔案都寫在命令列上。
FILES=(${(f)"$(cd -q "$TMP" && find src -type f | LC_ALL=C sort)"})
create_ok "operands" "$TMP/o.tar" $FILES
mkdir -p "$TMP/x3"; "$ST" -x -f "$TMP/o.tar" -C "$TMP/x3" >/dev/null 2>&1 || true
[ "$(manifest "$TMP/x3/src")" = "$WANT" ] && ok "operands: every file holds its own bytes" \
  || bad "operands: every file holds its own bytes"
listed=$("$ST" -t -f "$TMP/o.tar" 2>/dev/null | tr '\n' ' ')
[ "$listed" = "${(j: :)FILES} " ] && ok "operands: members are in command-line order" \
  || bad "operands: members are in command-line order"

# --update skips most files; the ones it writes must still be right.
# --update 會略過大部分檔案；寫出的那些仍必須正確。
cp "$TMP/a.tar" "$TMP/u.tar"
sleep 1
for d in 3 17 33; do head -c 4096 /dev/urandom > "$SRC/d$d/f7.bin"; done
run_limited "update" -u "$TMP/u.tar" src
mkdir -p "$TMP/x4"; "$ST" -x -f "$TMP/u.tar" -C "$TMP/x4" >/dev/null 2>&1 || true
[ "$(manifest "$TMP/x4/src")" = "$(manifest "$SRC")" ] && ok "update: the newer files land with their new bytes" \
  || bad "update: the newer files land with their new bytes"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
