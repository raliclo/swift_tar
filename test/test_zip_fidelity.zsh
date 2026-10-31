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

# Member order. The ZIP backend used to write members in the order the filesystem lists
# them, so one tree gave different archives on APFS and on tmpfs
# (verifications/cross_platform_bytes.zsh found it, 2026-10-13). It now sorts, and
# --zip-unsorted asks for the filesystem's order. The tar path sorts each directory and
# writes a directory before what is inside it; the ZIP listing has to match that listing.
# Enough names that an unsorted listing is not sorted by accident, and `d.x` beside `d1`
# because a plain sort of whole paths puts `d.x/f` in the wrong place.
# 成員順序。ZIP 後端原本依檔案系統列出的順序寫出成員，所以同一棵樹在 APFS 與 tmpfs 上得到
# 不同的封存（由 verifications/cross_platform_bytes.zsh 於 2026-10-13 找到）。現在它會排序，
# --zip-unsorted 則要求檔案系統的順序。tar 路徑會排序每個目錄，且目錄先於其內容；ZIP 的清單
# 必須與它相同。名稱要夠多，未排序的清單才不會碰巧是排序過的；`d.x` 與 `d1` 並列，是因為直接排序整條路徑會把 `d.x/f` 放錯位置。
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
  rc=0; ( cd -q "$ORD" && "$ST" -c $codec -f "$TMP/ord.zip" t ) >/dev/null 2>&1 || rc=$?
  eq "$codec order: -c exits 0" 0 "$rc"
  "$ST" -t -f "$TMP/ord.zip" 2>&1 | sed 's:/$::' > "$TMP/ord.zip.lst"
  cmp -s "$TMP/ord.tar.lst" "$TMP/ord.zip.lst" \
    && ok "$codec order: members are in the tar path's order" \
    || bad "$codec order: members are in the tar path's order"
  # With --zip-unsorted the order is the filesystem's, so only the set of members is
  # checked. / 加了 --zip-unsorted 時順序是檔案系統的，所以只檢查成員的集合。
  rc=0; ( cd -q "$ORD" && "$ST" -c $codec --zip-unsorted -f "$TMP/ord.zip" t ) >/dev/null 2>&1 || rc=$?
  eq "$codec --zip-unsorted order: -c exits 0" 0 "$rc"
  "$ST" -t -f "$TMP/ord.zip" 2>&1 | sed 's:/$::' | LC_ALL=C sort > "$TMP/ord.zip.set"
  LC_ALL=C sort "$TMP/ord.tar.lst" | cmp -s - "$TMP/ord.zip.set" \
    && ok "$codec --zip-unsorted order: the same members" \
    || bad "$codec --zip-unsorted order: the same members"
done
# --zip-unsorted where it cannot take effect is refused, not ignored.
# --zip-unsorted 用在起不了作用的地方時會被拒絕，而不是被忽略。
rc=0; ( cd -q "$ORD" && "$ST" -c --zip-unsorted -f "$TMP/ord.refused.tar" t ) >/dev/null 2>"$TMP/err.sorted" || rc=$?
eq "--zip-unsorted without --zip: exits 1" 1 "$rc"
[ -e "$TMP/ord.refused.tar" ] && bad "--zip-unsorted without --zip: writes no archive" \
  || ok "--zip-unsorted without --zip: writes no archive"
grep -q -- '--zip-unsorted' "$TMP/err.sorted" && ok "--zip-unsorted without --zip: stderr names the option" \
  || bad "--zip-unsorted without --zip: stderr names the option"
rc=0; "$ST" -t --zip-unsorted -f "$TMP/ord.zip" >/dev/null 2>&1 || rc=$?
eq "--zip-unsorted with -t: exits 1" 1 "$rc"

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
    ( cd -q "$GROW" && "$ST" -c -v $codec -f "$TMP/grow.zip" t ) >/dev/null 2>"$TMP/grow.fifo" &
    grow_pid=$!
    exec 3<"$TMP/grow.fifo"
    sleep 1
    print -r -- "grown after the walk" >> "$GROW/t/zzz"
    cat <&3 >/dev/null
    exec 3<&-
    rc=0; wait $grow_pid || rc=$?
    eq "$codec grow: -c exits 0 when a file grew after the walk" 0 "$rc"
    mkdir -p "$TMP/grow.out$codec"
    "$ST" -x -f "$TMP/grow.zip" -C "$TMP/grow.out$codec" >/dev/null 2>&1 || true
    cmp -s "$GROW/t/zzz" "$TMP/grow.out$codec/t/zzz" \
      && ok "$codec grow: the grown file is stored whole" \
      || bad "$codec grow: the grown file is stored whole"
    rm -f "$TMP/grow.fifo" "$TMP/grow.zip"
  done
else
  echo "SKIP: grow case (no mkfifo on this platform)"
fi

# Non-ASCII names on the command line. Measured on Windows 2026-10-31 (0.1.4 too): `-c --zip
# -f z.zip 資料.txt` exited 1 with "swift_tar: : Couldn't visit directory: left out", while
# `-cf t.tar 資料.txt` worked and a CJK name *inside* a directory operand was stored fine. The
# bridge opened each operand, and the archive itself, through libarchive's narrow API, which
# on Windows reads char* in the ANSI codepage, not as the UTF-8 Swift passes. The archive came
# out as `æªæ¡.zip` and `-t --zip -f 檔案.zip` could not open it. A missing operand was
# reported under libarchive's name for it, which is empty or stray memory there, so the
# message named the wrong file or none. POSIX passed all of this already; it runs everywhere.
# 命令列上的非 ASCII 名稱。2026-10-31 於 Windows 實測（0.1.4 亦然）：`-c --zip -f z.zip
# 資料.txt` 以 1 結束並印出「swift_tar: : Couldn't visit directory: left out」，而
# `-cf t.tar 資料.txt` 正常，目錄運算元「裡面」的中文名稱也存得好好的。bridge 以 libarchive 的
# 窄字元 API 開啟每個運算元與封存本身，而它在 Windows 上把 char* 當 ANSI 代碼頁讀，不是 Swift
# 傳入的 UTF-8。封存檔變成 `æªæ¡.zip`，`-t --zip -f 檔案.zip` 也開不了。不存在的運算元以
# libarchive 對它的名稱回報，在那裡是空字串或記憶體殘渣，於是訊息指錯檔案或沒有名稱。POSIX
# 本來就全部通過；這段在每個平台都執行。
CJK="$TMP/cjk"
mkdir -p "$CJK"
print -r -- data > "$CJK/資料.txt"
for v in "" "--zip-unsorted"; do
  label="--zip${v:+ $v}"
  rm -f -- "$CJK"/*.zip(N)
  rc=0; ( cd -q "$CJK" && "$ST" -c --zip ${=v} -f z.zip 資料.txt ) >/dev/null 2>"$TMP/cjk.err" || rc=$?
  eq "$label CJK operand: -c exits 0" 0 "$rc"
  [ -s "$TMP/cjk.err" ] && bad "$label CJK operand: -c says nothing on stderr ($(head -c 160 "$TMP/cjk.err"))" \
    || ok "$label CJK operand: -c says nothing on stderr"
  eq "$label CJK operand: -t lists it" 資料.txt "$(cd -q "$CJK" && "$ST" -t --zip -f z.zip 2>&1)"
  # General purpose bit 11 (UTF-8 names) is bit 3 of the flag word's high byte, offset 7 of the
  # first local header. / 通用旗標第 11 位元（UTF-8 名稱）是旗標字高位元組的第 3 位元，位於第一個
  # 本地標頭的位移 7。
  flags_hi=$(od -A n -t u1 -j 7 -N 1 "$CJK/z.zip" 2>/dev/null | tr -d ' ')
  (( ${flags_hi:-0} & 8 )) && ok "$label CJK operand: the UTF-8 flag (bit 11) is set" \
    || bad "$label CJK operand: the UTF-8 flag (bit 11) is set (high flag byte '${flags_hi}')"

  rc=0; ( cd -q "$CJK" && "$ST" -c --zip ${=v} -f 檔案.zip 資料.txt ) >/dev/null 2>"$TMP/cjk.err" || rc=$?
  [ "$rc" = 0 ] && [ -f "$CJK/檔案.zip" ] && ok "$label CJK archive name: written under that name" \
    || bad "$label CJK archive name: written under that name (rc $rc; $(cd -q "$CJK" && print -r -- *.zip(N)))"
  eq "$label CJK archive name: -t opens it" 資料.txt "$(cd -q "$CJK" && "$ST" -t --zip -f 檔案.zip 2>&1)"

  rc=0; ( cd -q "$CJK" && "$ST" -c --zip ${=v} -f z2.zip 資料.txt 不存在的檔案.txt ) >/dev/null 2>"$TMP/cjk.err" || rc=$?
  eq "$label missing CJK operand: exits 1" 1 "$rc"
  grep -qF '不存在的檔案.txt: ' "$TMP/cjk.err" && ok "$label missing CJK operand: stderr names it" \
    || bad "$label missing CJK operand: stderr names it ($(head -c 200 "$TMP/cjk.err"))"
  grep -qF '資料.txt' "$TMP/cjk.err" && bad "$label missing CJK operand: the file that exists is not blamed" \
    || ok "$label missing CJK operand: the file that exists is not blamed"
  eq "$label missing CJK operand: the rest is stored" 資料.txt "$(cd -q "$CJK" && "$ST" -t --zip -f z2.zip 2>&1)"

  # The archive inside the tree it archives is left out by identity; on Windows the walk's
  # name for it went through the "C" locale and matched nothing, so it was stored in itself.
  # 位於被封存樹內的封存檔以身分排除；Windows 上走訪對它的名稱經過 "C" locale，什麼也比對
  # 不到，於是它被存進了自己。
  mkdir -p "$CJK/self"; print -r -- y > "$CJK/self/f.txt"; rm -f "$CJK/self/封存.zip"
  rc=0; ( cd -q "$CJK/self" && "$ST" -c --zip ${=v} -f 封存.zip . ) >/dev/null 2>"$TMP/cjk.err" || rc=$?
  ( cd -q "$CJK/self" && "$ST" -t --zip -f 封存.zip ) 2>&1 | grep -qF '封存.zip' \
    && bad "$label CJK archive name inside the tree: not stored in itself" \
    || ok "$label CJK archive name inside the tree: not stored in itself"
  grep -qF "封存.zip: Can't add archive to itself" "$TMP/cjk.err" \
    && ok "$label CJK archive name inside the tree: stderr says so" \
    || bad "$label CJK archive name inside the tree: stderr says so ($(head -c 200 "$TMP/cjk.err"))"
done
# A missing CJK archive is named as it was typed, not as '??.zip' (Windows, 2026-10-31).
# 不存在的中文封存檔以輸入時的名稱回報，而不是 '??.zip'（Windows，2026-10-31）。
rc=0; ( cd -q "$CJK" && "$ST" -t --zip -f 沒有.zip ) >/dev/null 2>"$TMP/cjk.err" || rc=$?
[ "$rc" != 0 ] && grep -qF "'沒有.zip'" "$TMP/cjk.err" && ok "missing CJK archive: stderr names it" \
  || bad "missing CJK archive: stderr names it (rc $rc; $(head -c 200 "$TMP/cjk.err"))"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
