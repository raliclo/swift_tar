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

# Member order. By default the ZIP backend writes members in the order the filesystem
# lists them, so one tree gives different archives on APFS and on tmpfs
# (verifications/cross_platform_bytes.zsh found it, 2026-10-13); --zip-sorted asks for a
# fixed order at the price of holding the file list in memory. The tar path sorts each
# directory and writes a directory before what is inside it; with --zip-sorted the ZIP
# listing has to match that listing.
# Enough names that an unsorted listing is not sorted by accident, and `d.x` beside `d1`
# because a plain sort of whole paths puts `d.x/f` in the wrong place.
# 成員順序。ZIP 後端預設依檔案系統列出的順序寫出成員，所以同一棵樹在 APFS 與 tmpfs 上得到
# 不同的封存（由 verifications/cross_platform_bytes.zsh 於 2026-10-13 找到）；--zip-sorted
# 要求固定的順序，代價是把檔案清單留在記憶體。tar 路徑會排序每個目錄，且目錄先於其內容；
# 加了 --zip-sorted，ZIP 的清單必須與它相同。名稱要夠多，未排序的清單才不會碰巧
# 是排序過的；`d.x` 與 `d1` 並列，是因為直接排序整條路徑會把 `d.x/f` 放錯位置。
ORD="$TMP/ord"
mkdir -p "$ORD/t/d2/sub" "$ORD/t/d1" "$ORD/t/d.x"
for n in zeta alpha m.txt k9 b a.b q1 q2 q3 w e r t y u i o p; do
  print -r -- $n > "$ORD/t/$n"
  print -r -- $n > "$ORD/t/d2/$n"
  print -r -- $n > "$ORD/t/d2/sub/$n"
done
print -r -- x > "$ORD/t/d1/f"
print -r -- x > "$ORD/t/d.x/f"
( cd -q "$ORD" && "$ST" -c -f "$TMP/ord.tar" t ) >/dev/null 2>&1
"$ST" -t -f "$TMP/ord.tar" 2>&1 | sed 's:/$::' > "$TMP/ord.tar.lst"
eq "order: the tar listing has every member" 61 "$(wc -l < "$TMP/ord.tar.lst" | tr -d ' ')"
for codec in --zip --zip64; do
  rc=0; ( cd -q "$ORD" && "$ST" -c $codec --zip-sorted -f "$TMP/ord.zip" t ) >/dev/null 2>&1 || rc=$?
  eq "$codec --zip-sorted order: -c exits 0" 0 "$rc"
  "$ST" -t -f "$TMP/ord.zip" 2>&1 | sed 's:/$::' > "$TMP/ord.zip.lst"
  cmp -s "$TMP/ord.tar.lst" "$TMP/ord.zip.lst" \
    && ok "$codec --zip-sorted order: members are in the tar path's order" \
    || bad "$codec --zip-sorted order: members are in the tar path's order"
  # Without --zip-sorted the order is the filesystem's, so only the set of members is
  # checked. / 不加 --zip-sorted 時順序是檔案系統的，所以只檢查成員的集合。
  rc=0; ( cd -q "$ORD" && "$ST" -c $codec -f "$TMP/ord.zip" t ) >/dev/null 2>&1 || rc=$?
  eq "$codec order: -c exits 0 without --zip-sorted" 0 "$rc"
  "$ST" -t -f "$TMP/ord.zip" 2>&1 | sed 's:/$::' | LC_ALL=C sort > "$TMP/ord.zip.set"
  LC_ALL=C sort "$TMP/ord.tar.lst" | cmp -s - "$TMP/ord.zip.set" \
    && ok "$codec order: the same members without --zip-sorted" \
    || bad "$codec order: the same members without --zip-sorted"
done
# --zip-sorted where it cannot take effect is refused, not ignored.
# --zip-sorted 用在起不了作用的地方時會被拒絕，而不是被忽略。
rc=0; ( cd -q "$ORD" && "$ST" -c --zip-sorted -f "$TMP/ord.refused.tar" t ) >/dev/null 2>"$TMP/err.sorted" || rc=$?
eq "--zip-sorted without --zip: exits 1" 1 "$rc"
[ -e "$TMP/ord.refused.tar" ] && bad "--zip-sorted without --zip: writes no archive" \
  || ok "--zip-sorted without --zip: writes no archive"
grep -q -- '--zip-sorted' "$TMP/err.sorted" && ok "--zip-sorted without --zip: stderr names the option" \
  || bad "--zip-sorted without --zip: stderr names the option"
rc=0; "$ST" -t --zip-sorted -f "$TMP/ord.zip" >/dev/null 2>&1 || rc=$?
eq "--zip-sorted with -t: exits 1" 1 "$rc"

# A file that grows after the walk. Sorting means every member is listed before the first
# one is written, so a file's size is recorded long before its turn; the backend reads it
# again at that point, and without that a grown file does not fit its own header and the run
# ends there. To hold the writer between the walk and the last member, -v goes to a FIFO
# nobody is reading yet: 1200 long names are more than a pipe holds, so it stops part-way.
# If the machine is slow enough that the walk has not finished after the sleep, the case
# passes without testing anything; it cannot fail for that reason.
# 走訪之後才變大的檔案。排序意味著所有成員都先列出、才寫出第一個，所以檔案的大小在輪到它
# 之前很久就記下了；後端在輪到時會重讀一次，否則變大的檔案會超出自己標頭裡的大小，整次執行
# 就停在那裡。為了讓寫出端停在走訪與最後一個成員之間，-v 導向一個還沒人讀的 FIFO：1200 個
# 長檔名超過 pipe 的容量，所以它會停在半途。若機器慢到 sleep 之後走訪仍未結束，這項會在
# 沒測到東西的情況下通過；它不會因此失敗。
if (( HAVE_FIFO )); then
  GROW="$TMP/grow"
  mkdir -p "$GROW/t"
  pad="$(printf 'x%.0s' {1..90})"
  for i in {1..1200}; do : > "$GROW/t/a_${pad}_$i"; done
  print -r -- short > "$GROW/t/zzz"
  for codec in --zip --zip64; do
    print -r -- short > "$GROW/t/zzz"
    mkfifo "$TMP/grow.fifo"
    ( cd -q "$GROW" && "$ST" -c -v $codec --zip-sorted -f "$TMP/grow.zip" t ) >/dev/null 2>"$TMP/grow.fifo" &
    grow_pid=$!
    exec 3<"$TMP/grow.fifo"
    sleep 1
    print -r -- "grown after the walk" >> "$GROW/t/zzz"
    cat <&3 >/dev/null
    exec 3<&-
    rc=0; wait $grow_pid || rc=$?
    eq "$codec --zip-sorted grow: -c exits 0 when a file grew after the walk" 0 "$rc"
    mkdir -p "$TMP/grow.out$codec"
    "$ST" -x -f "$TMP/grow.zip" -C "$TMP/grow.out$codec" >/dev/null 2>&1 || true
    cmp -s "$GROW/t/zzz" "$TMP/grow.out$codec/t/zzz" \
      && ok "$codec --zip-sorted grow: the grown file is stored whole" \
      || bad "$codec --zip-sorted grow: the grown file is stored whole"
    rm -f "$TMP/grow.fifo" "$TMP/grow.zip"
  done
else
  echo "SKIP: grow case (no mkfifo on this platform)"
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
