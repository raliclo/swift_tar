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

# Windows: the fixtures below create symlinks, one of them dangling (f20_dangling),
# which needs winsymlinks:native -- nativestrict cannot make a symlink to a target
# that does not exist. And Windows has no filesystem FIFO, so the mkfifo fixture is
# skipped there rather than aborting the whole run under set -e. The FIFO case tests
# a POSIX-only property (ReadAhead must not block on a FIFO, via O_NONBLOCK), which
# does not apply on the Windows -c path at all.
# Windows：下方夾具會建 symlink，其中一個是 dangling（f20_dangling），需
# winsymlinks:native——nativestrict 無法對不存在的目標建 symlink。且 Windows 無檔案系統
# FIFO，故 mkfifo 夾具在該平台改為 skip，而非在 set -e 下中止整個測試。FIFO 案例驗的是
# POSIX 專屬性質（ReadAhead 以 O_NONBLOCK 確保不卡在 FIFO），在 Windows 的 -c 路徑根本不適用。
# MSYS is OVERWRITTEN here, not appended to. The 2026-10-14 review proposed appending
# (`winsymlinks:native ${MSYS:-}`) to keep any other options the environment set; measured that
# day, that breaks the fixture on this machine. This machine's zsh exports
# MSYS=winsymlinks:nativestrict at startup, and a later winsymlinks: token does NOT override an
# earlier one -- "winsymlinks:native winsymlinks:nativestrict" still acts as nativestrict, which
# refuses a symlink to a missing target, so f20_dangling cannot be created and `ln -s` aborts the
# run. The inherited value is the very thing that has to be overridden, so a plain assignment is
# correct. (The append also leaves a trailing space when MSYS is unset, which the MSYS ln runtime
# then fails to parse at all -- a second way the same suggestion breaks.)
# 這裡是「覆蓋」MSYS，不是 append。2026-10-14 審查建議 append（`winsymlinks:native ${MSYS:-}`）以
# 保留環境其他選項；當日實測，在本機會弄壞夾具。本機 zsh 啟動時就 export
# MSYS=winsymlinks:nativestrict，而較後的 winsymlinks: token 並不會覆蓋較前的——
# 「winsymlinks:native winsymlinks:nativestrict」仍作用為 nativestrict，它拒絕對不存在目標建
# symlink，於是 f20_dangling 建不出來、`ln -s` 中止整個測試。繼承來的值正是必須被覆蓋的東西，故
# 直接覆蓋才對。（append 在 MSYS 未設時還會留下尾隨空白，MSYS ln runtime 根本解析不出——同一建議
# 弄壞它的第二種方式。）
IS_WIN=0
case "$(uname -s)" in MSYS*|MINGW*|CYGWIN*) IS_WIN=1; export MSYS=winsymlinks:native ;; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Contents of every regular file, by path. / 依路徑列出每個一般檔案的內容雜湊。
# Neither choice requires Perl. / 兩種選擇皆不依賴 Perl。
if command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum); else SHA256=(openssl dgst -sha256 -r); fi
manifest() { ( cd -q "$1" && find . -type f | LC_ALL=C sort | xargs "${SHA256[@]}" ) | "${SHA256[@]}" | cut -c1-16; }

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
# mkfifo via `if` so a platform without FIFOs (Windows) skips rather than aborting
# under set -e. / 以 if 包住 mkfifo，使無 FIFO 的平台（Windows）skip 而非在 set -e 下中止。
have_fifo=0
if mkfifo "$SRC/d6/f12_fifo" 2>/dev/null; then have_fifo=1; fi
print -r -- skipme > "$SRC/d7/f13.skip"

WANT=$(manifest "$SRC")

create_ok "tree" "$TMP/a.tar" src
mkdir -p "$TMP/x1"; "$ST" -x -f "$TMP/a.tar" -C "$TMP/x1" >/dev/null 2>&1 || true
[ "$(manifest "$TMP/x1/src")" = "$WANT" ] && ok "tree: every file holds its own bytes" \
  || bad "tree: every file holds its own bytes"
[ -L "$TMP/x1/src/d4/f10_link" ] && ok "tree: a symlink stays a symlink" || bad "tree: a symlink stays a symlink"
# The DANGLING link (target absent) is the case 4d24b8d set out to fix, and the 2026-10-14
# review found it untested: manifest() uses `find -type f`, which skips every symlink, and
# f10_link above has a target that exists. On Windows this also measures winStat's reparse
# handling end to end -- if destinationOfSymbolicLink returned nil for a target-less link,
# winStat would class the dangling link as a regular file and -c would fail again (finding (a));
# if it returned an empty string, the link would round-trip with an empty target (finding (b)).
# `-L` catches the first, the `*nonexistent*` match catches the second.
# 斷鏈連結（目標不存在）是 4d24b8d 要修的案例，2026-10-14 審查發現它沒被測到：manifest() 用
# find -type f 跳過所有 symlink，而上面的 f10_link 目標存在。在 Windows 這也端到端量到 winStat 的
# reparse 處理——若 destinationOfSymbolicLink 對無目標連結回 nil，winStat 會把斷鏈連結判成一般檔案、
# -c 又會失敗（(a)）；若回空字串，連結會以空目標往返（(b)）。-L 抓前者，*nonexistent* 比對抓後者。
if [ -L "$TMP/x1/src/d4/f20_dangling" ]; then
  dangle_tgt="$(readlink "$TMP/x1/src/d4/f20_dangling" 2>/dev/null)"
  case "$dangle_tgt" in
    (*nonexistent*) ok "tree: a dangling symlink round-trips to its target" ;;
    (*) bad "tree: a dangling symlink round-trips to its target (target=[$dangle_tgt])" ;;
  esac
else
  bad "tree: a dangling symlink round-trips to its target (extracted as a non-link)"
fi
if (( have_fifo )); then
  [ -p "$TMP/x1/src/d6/f12_fifo" ] && ok "tree: a FIFO is archived as a FIFO, without blocking" \
    || bad "tree: a FIFO is archived as a FIFO, without blocking"
else
  echo "SKIP: FIFO case — no mkfifo on this platform / 此平台無 mkfifo"
fi

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
