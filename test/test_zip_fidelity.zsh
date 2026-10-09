#!/usr/bin/env zsh
# test_zip_fidelity.zsh -- a ZIP round trip keeps directory times and FIFOs, and the same tree
# archived twice gives the same bytes. For --zip and --zip64.
# test_zip_fidelity.zsh -- ZIP 往返保留目錄時間與 FIFO，且同一棵樹封存兩次得到相同的位元組。
# 涵蓋 --zip 與 --zip64。
#
#   ./test/test_zip_fidelity.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_zip_fidelity.zsh    # a specific binary
#
# All three failed until 2026-10-09, while every tar codec passed the same round trip:
#   - directory times: the bridge chdir'ed out of -C before closing libarchive's disk writer,
#     which applies directory times at close by relative path, so they landed nowhere;
#   - FIFOs: libarchive's ZIP writer refused them and its reader turned a FIFO entry into a
#     regular file (patch/libarchive/0002-zip-store-fifo.patch);
#   - reproducibility: atime and ctime went into each entry's UT extra field.
# 這三項在 2026-10-09 之前都失敗，而同樣的往返在每個 tar codec 上都通過：
#   - 目錄時間：bridge 先 chdir 離開 -C 才關閉 libarchive 的 disk writer，而它在關閉時才依
#     相對路徑套用目錄時間，於是無處落地；
#   - FIFO：libarchive 的 ZIP 寫出端拒收，讀取端又把 FIFO 項目轉成一般檔案
#     （patch/libarchive/0002-zip-store-fifo.patch）；
#   - 可重現：atime 與 ctime 被寫進每個項目的 UT 擴充欄位。
set -euo pipefail
zmodload zsh/stat

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,23p' "$script_path" | sed 's/^# \{0,1\}//'
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

# mtime of a path, not following a symlink. / 路徑的 mtime，不跟隨 symlink。
mtime() { zstat -L +mtime "$1" 2>/dev/null || print -r -- absent; }

SRC="$TMP/src"
mkdir -p "$SRC/tree/a/b" "$SRC/tree/c"
print -r -- one > "$SRC/tree/a/b/f1.txt"
print -r -- two > "$SRC/tree/c/f2.txt"
ln -s ../c/f2.txt "$SRC/tree/a/link"
HAVE_FIFO=0
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) mkfifo "$SRC/tree/c/pipe" && HAVE_FIFO=1 ;;
esac
# Old, distinct directory times, deepest first so writing a child does not undo them.
# 久遠且各不相同的目錄時間，由深至淺設定，以免寫入子項目時又被改掉。
touch -t 201001010101.01 "$SRC/tree/a/b"
touch -t 201102020202.02 "$SRC/tree/a"
touch -t 201203030303.03 "$SRC/tree/c"
touch -t 201304040404.04 "$SRC/tree"

for codec in --zip --zip64; do
  rm -rf "$TMP/out" "$TMP/z1" "$TMP/z2"; mkdir -p "$TMP/out"
  ( cd -q "$SRC" && "$ST" -c $codec -f "$TMP/z1" tree ) >/dev/null 2>"$TMP/err1" || true
  [ -s "$TMP/err1" ] && bad "$codec: -c says nothing on stderr ($(head -c 160 "$TMP/err1"))" \
    || ok "$codec: -c says nothing on stderr"
  # Move every atime between the two runs; the second archive must not change for it. Set
  # explicitly rather than by reading again: APFS does not update atime on every read, and
  # an earlier version that only slept and re-read passed against the binary it was for.
  # 在兩次之間改動每個 atime；第二份封存不得因此不同。明確設定而非靠再讀一次：APFS 不會在
  # 每次讀取時更新 atime，先前只睡一秒再讀的版本對著有問題的 binary 也通過了。
  find "$SRC/tree" ! -type p -exec touch -h -a -t 202402020202.02 {} +
  ( cd -q "$SRC" && "$ST" -c $codec -f "$TMP/z2" tree ) >/dev/null 2>&1 || true
  cmp -s "$TMP/z1" "$TMP/z2" && ok "$codec: the same tree archived twice gives the same bytes" \
    || bad "$codec: the same tree archived twice gives the same bytes"

  rc=0; "$ST" -x -f "$TMP/z1" -C "$TMP/out" >/dev/null 2>"$TMP/errx" || rc=$?
  eq "$codec: -x exits 0" 0 "$rc"
  for d in tree tree/a tree/a/b tree/c; do
    eq "$codec: directory '$d' keeps its time" "$(mtime "$SRC/$d")" "$(mtime "$TMP/out/$d")"
  done
  eq "$codec: a file keeps its contents" one "$(cat "$TMP/out/tree/a/b/f1.txt" 2>/dev/null)"
  [ -L "$TMP/out/tree/a/link" ] && ok "$codec: a symlink stays a symlink" \
    || bad "$codec: a symlink stays a symlink"
  if (( HAVE_FIFO )); then
    [ -p "$TMP/out/tree/c/pipe" ] && ok "$codec: a FIFO comes back as a FIFO" \
      || bad "$codec: a FIFO comes back as a FIFO"
  else
    echo "SKIP: $codec FIFO case (no mkfifo on this platform)"
  fi
done

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
