#!/usr/bin/env zsh
# test_zip_parallel.zsh -- -c --zip compresses members on several threads (-n), and the
# archive is the same bytes whatever -n is. For --zip and --zip64.
# test_zip_parallel.zsh -- -c --zip 以多個執行緒壓縮成員（-n），且不論 -n 為何，封存的位元組
# 都相同。涵蓋 --zip 與 --zip64。
#
#   ./test/test_zip_parallel.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_zip_parallel.zsh    # a specific binary
#
# Until 2026-10-14 the ZIP backend compressed on one thread: libarchive's ZIP writer
# deflates each member as it is written. Now worker threads read and deflate regular files
# ahead of the writer, and the writer puts each finished stream in place through
# patch/libarchive/0003. What has to hold:
#   - the bytes do not depend on -n, in either member order, with or without -C;
#   - a reader that is not swift_tar (`unzip -t`) accepts the result;
#   - -v lists members in the same order;
#   - a file that cannot be read ends the run with 1 and the same message as with -n 1;
#   - the threads are really used, where the build has them. That last check is what tells
#     a build that silently fell back to one thread from one that did not: everything else
#     here passes on one thread too.
# 2026-10-14 之前，ZIP 後端只用一個執行緒壓縮：libarchive 的 ZIP 寫出端是在寫出每個成員時才
# deflate。現在由工作執行緒走在寫出端之前讀取並 deflate 一般檔案，寫出端再經由
# patch/libarchive/0003 把完成的串流放進去。必須成立的事：
#   - 位元組與 -n 無關，兩種成員順序皆然，有沒有 -C 皆然；
#   - 不是 swift_tar 的讀取端（`unzip -t`）接受這個結果；
#   - -v 列出成員的順序相同；
#   - 讀不到的檔案使執行以 1 結束，訊息與 -n 1 相同；
#   - 在建置有執行緒的地方，執行緒真的有被用到。最後這一項，才分得出「悄悄退回一個執行緒」的
#     建置與沒有退回的建置：這裡其他每一項，一個執行緒也都會通過。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,29p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
HERE="${script_path:h}"
ROOT="${HERE:h}"
POSIX=1
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) POSIX=0; VERSION_FILE="$ROOT/version-win.txt"; : "${ST:=$ROOT/release/swift_tar.exe}" ;;
  Darwin) VERSION_FILE="$ROOT/version-mac.txt"; : "${ST:=$ROOT/release/swift_tar}" ;;
  *) VERSION_FILE="$ROOT/version-linux.txt"; : "${ST:=$ROOT/release/swift_tar}" ;;
esac
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }
same() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1"; fi; }

# ---- the tree ----------------------------------------------------------------------------
# More members than the writer holds at once (256), so the window fills and empties; files
# of very different sizes, so they finish out of order; an empty file, a link and a FIFO,
# which carry no data for a worker; and one file above the size (64 MiB) that is compressed
# by the writing thread instead of a worker.
# 成員數多於寫出端一次留住的數量（256），所以視窗會填滿又清空；檔案大小差異很大，所以完成的
# 順序會與交付的順序不同；一個空檔案、一個連結與一個 FIFO，它們沒有資料可交給工作執行緒；
# 以及一個超過門檻（64 MiB）的檔案，它由負責寫出的執行緒壓縮，而不是工作執行緒。
SRC="$TMP/src"
#
# `empties` comes first and holds more empty files than the window: members with no data
# pass through without a worker ever being woken, and the first file after them was once
# compressed five times over (the workers were still looking at places in the window that
# had since been reused).
# `empties` 排在最前面，裡面的空檔案比視窗還多：沒有資料的成員通過時不會喚醒任何工作執行緒，
# 而緊接在它們之後的第一個檔案曾經被重複壓縮五次（工作執行緒還在看視窗裡早已被重用的位置）。
mkdir -p "$SRC/t/empties" "$SRC/t/many" "$SRC/t/sized/deeper" "$SRC/t/text"
( cd -q "$SRC/t/empties" && : > e{001..700} )
for i in {001..600}; do print -r -- "member $i" > "$SRC/t/many/f$i"; done
: > "$SRC/t/sized/empty"
print -rn -- x > "$SRC/t/sized/one-byte"
head -c 70000 /dev/urandom > "$SRC/t/sized/random-70k"
head -c 700000 /dev/urandom | od -An -tx1 > "$SRC/t/sized/deeper/hex-2m"
head -c 200000 /dev/urandom | od -An -tx1 > "$SRC/t/sized/deeper/hex-600k"
dd if=/dev/zero of="$SRC/t/sized/zeros-65m" bs=1048576 count=65 2>/dev/null
for i in {1..8}; do head -c 500000 /dev/urandom | od -An -tx1 > "$SRC/t/text/hex$i"; done
if [ "$POSIX" = 1 ]; then
  ln -s ../many/f001 "$SRC/t/sized/link"
  mkfifo "$SRC/t/sized/pipe"
fi

# ---- the bytes do not depend on -n -------------------------------------------------------
for codec in --zip --zip64; do
  for order in "" --zip-unsorted; do
    label="$codec${order:+ $order}"
    rc=0; ( cd -q "$SRC" && "$ST" -c $codec $order -n 1 -f "$TMP/n1.zip" t ) >/dev/null 2>&1 || rc=$?
    eq "$label: -n 1 exits 0" 0 "$rc"
    for n in 2 4 16; do
      rc=0; ( cd -q "$SRC" && "$ST" -c $codec $order -n $n -f "$TMP/n.zip" t ) >/dev/null 2>&1 || rc=$?
      eq "$label: -n $n exits 0" 0 "$rc"
      same "$label: -n $n gives the same bytes as -n 1" "$TMP/n1.zip" "$TMP/n.zip"
    done
    # -C, and from a directory that is not the tree's parent: relative paths are opened by
    # the workers against the directory -C named, not the one the walk happens to be in.
    # -C，且從不是樹的上層的目錄執行：工作執行緒是相對於 -C 指定的目錄開啟相對路徑，而不是
    # 走訪當下所在的目錄。
    rc=0; ( cd -q "$TMP" && "$ST" -c $codec $order -n 8 -f "$TMP/n.zip" -C "$SRC" t ) >/dev/null 2>&1 || rc=$?
    eq "$label: -n 8 with -C exits 0" 0 "$rc"
    same "$label: -n 8 with -C gives the same bytes as -n 1" "$TMP/n1.zip" "$TMP/n.zip"
  done

  # What is in it, read back by swift_tar and by a reader that is not swift_tar.
  # 裡面的內容，由 swift_tar 讀回，也由不是 swift_tar 的讀取端讀回。
  ( cd -q "$SRC" && "$ST" -c $codec -n 8 -f "$TMP/n.zip" t ) >/dev/null 2>&1
  rm -rf "$TMP/out"; mkdir "$TMP/out"
  rc=0; "$ST" -x -f "$TMP/n.zip" -C "$TMP/out" >/dev/null 2>&1 || rc=$?
  eq "$codec: -x of the -n 8 archive exits 0" 0 "$rc"
  for f in many/f001 many/f600 sized/empty sized/one-byte sized/random-70k sized/deeper/hex-2m \
           sized/deeper/hex-600k sized/zeros-65m text/hex1 text/hex8; do
    same "$codec: $f comes back the same" "$SRC/t/$f" "$TMP/out/t/$f"
  done
  eq "$codec: every member is in the -n 8 archive" \
     "$(find "$SRC/t" | wc -l | tr -d ' ')" "$("$ST" -t -f "$TMP/n.zip" | wc -l | tr -d ' ')"
  if command -v unzip >/dev/null 2>&1; then
    rc=0; unzip -tq "$TMP/n.zip" >/dev/null 2>&1 || rc=$?
    eq "$codec: unzip -t accepts the -n 8 archive" 0 "$rc"
  else
    echo "SKIP: $codec unzip -t (no unzip on this machine)"
  fi

  # -v names members as they are written, so the lists match line for line.
  # -v 是在寫出成員時才印出名稱，所以兩份清單逐行相同。
  ( cd -q "$SRC" && "$ST" -c -v $codec -n 1 -f "$TMP/n.zip" t ) >/dev/null 2>"$TMP/v1.txt"
  ( cd -q "$SRC" && "$ST" -c -v $codec -n 8 -f "$TMP/n.zip" t ) >/dev/null 2>"$TMP/v8.txt"
  same "$codec: -v lists the same members in the same order with -n 8" "$TMP/v1.txt" "$TMP/v8.txt"
  rm -f "$TMP/n.zip" "$TMP/n1.zip"
done

# ---- a file that cannot be read ----------------------------------------------------------
# Not as root, which reads it anyway. / root 照樣讀得到，所以不以 root 執行這一項。
if [ "$POSIX" = 1 ] && [ "$EUID" != 0 ]; then
  BADDIR="$TMP/bad"
  mkdir -p "$BADDIR/t"
  for i in {01..40}; do print -r -- "member $i" > "$BADDIR/t/f$i"; done
  chmod 000 "$BADDIR/t/f20"
  rc=0; ( cd -q "$BADDIR" && "$ST" -c --zip -n 1 -f "$TMP/bad1.zip" t ) >/dev/null 2>"$TMP/bad1.err" || rc=$?
  eq "unreadable file: -n 1 exits 1" 1 "$rc"
  rc=0; ( cd -q "$BADDIR" && "$ST" -c --zip -n 8 -f "$TMP/bad8.zip" t ) >/dev/null 2>"$TMP/bad8.err" || rc=$?
  eq "unreadable file: -n 8 exits 1" 1 "$rc"
  same "unreadable file: -n 8 says what -n 1 says" "$TMP/bad1.err" "$TMP/bad8.err"
  grep -q 'f20' "$TMP/bad8.err" && ok "unreadable file: stderr names the file" \
    || bad "unreadable file: stderr names the file"
  chmod 644 "$BADDIR/t/f20"
else
  echo "SKIP: unreadable-file case (needs POSIX permissions and a non-root user)"
fi

# ---- the threads are used ----------------------------------------------------------------
# CPU time against elapsed time, compressing eight files of the same size. On one thread
# the two are about equal; on four the CPU time is a multiple of the elapsed time. Where
# the build has no threaded path (Windows, or a libarchive that is not the patched static
# one) there is nothing to assert, and the case says so instead of passing.
# 壓縮八個大小相同的檔案時，CPU 時間與經過時間的比。一個執行緒時兩者大致相等；四個時，CPU 時間
# 是經過時間的數倍。建置沒有執行緒路徑的地方（Windows，或 libarchive 不是打過 patch 的靜態庫）
# 沒有可斷言的東西，這一項會明說略過，而不是通過。
#
# Four cores, and the better of three runs each way. With two cores the most -n 4 can show
# is 200%, and the one writing thread and the reads are serial, so a busy machine or a slow
# disk put a sound binary under the 160 asked for; a single timing also left -n 1 wandering
# about its 130. A run that did use the threads shows it in at least one of three.
# 要四個核心，且兩邊各取三次中較好的一次。只有兩核時 -n 4 最多只看得到 200%，而寫出的那個
# 執行緒與讀取都是循序的，機器一忙或磁碟一慢，沒問題的執行檔也會低於所要求的 160；只計時一次，
# 也讓 -n 1 在 130 上下飄。真的用到執行緒的話，三次裡至少有一次看得出來。
cores=$( (getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1) | head -1 )
if [ "$POSIX" = 1 ] && [ "$cores" -ge 4 ] && grep -q '^libarchive_linkage=static' "$VERSION_FILE" 2>/dev/null; then
  ratio() {  # ratio N -> CPU time / elapsed time, in hundredths
    local TIMEFMT='%U %S %E' line
    line=$( { time "$ST" -c --zip -n $1 -f "$TMP/cpu.zip" -C "$SRC/t" text >/dev/null 2>/dev/null; } 2>&1 | tail -1 )
    line=${line//s/}
    printf "%.0f\n" $(( (${line[(w)1]} + ${line[(w)2]}) * 100.0 / (${line[(w)3]} > 0 ? ${line[(w)3]} : 0.001) ))
  }
  one=$(ratio 1); four=$(ratio 4)
  for again in 2 3; do
    r=$(ratio 1); [ "$r" -lt "$one" ] && one=$r
    r=$(ratio 4); [ "$r" -gt "$four" ] && four=$r
  done
  if [ "$one" -lt 130 ]; then ok "threads: -n 1 uses about one core ($one% of elapsed)"
  else bad "threads: -n 1 uses about one core ($one% of elapsed)"; fi
  if [ "$four" -ge 160 ]; then ok "threads: -n 4 uses more than one core ($four% of elapsed)"
  else bad "threads: -n 4 uses more than one core ($four% of elapsed)"; fi
else
  echo "SKIP: thread-use case (no threaded ZIP path in this build, or fewer than four cores)"
fi

# --help said "-n: default 2×cores" long after the code had gone to one per core (the 2×
# measured 2.7% faster for twice the memory). With -n now also the ZIP thread count, the
# wrong default was being read by more people.
# --help 的 -n 寫著「預設 2×核心數」，而程式早已改為每個核心一個（2× 只快 2.7%，記憶體加倍）。
# -n 現在也是 ZIP 的執行緒數，讀到那個錯誤預設值的人更多了。
help_text=$("$ST" --help 2>&1)
if print -r -- "$help_text" | grep -q 'default: one per core' && ! print -r -- "$help_text" | grep -q -E '2×cores|2×核心數'; then
  ok "--help gives the -n default as one per core"
else
  bad "--help gives the -n default as one per core"
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
