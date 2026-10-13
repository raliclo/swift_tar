#!/usr/bin/env zsh
# test_zip_sorted.zsh -- --zip-sorted lists one directory at a time and keeps only names:
# what that walk has to get right by itself. For --zip and --zip64.
# test_zip_sorted.zsh -- --zip-sorted 一次只列一個目錄，且只記名稱：這個走訪必須自己做對的事。
# 涵蓋 --zip 與 --zip64。
#
#   ./test/test_zip_sorted.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_zip_sorted.zsh    # a specific binary
#
# Until 2026-10-13 --zip-sorted collected every entry of the tree and sorted them at once
# (1.79 GB for 1,001,377 entries). It now opens libarchive's walk on one directory at a
# time, which takes three things away from libarchive that are checked here:
#   - memory: it must follow the largest directory, not the size of the tree;
#   - -h and links that lead back up: libarchive stopped those from its own stack, which is
#     now one level deep, so the walk carries the directories above it;
#   - open directories: only one may be open at a time, or a deep tree runs out of file
#     descriptors.
# The order itself, and a file that grows during the run, are in test_zip_fidelity.zsh.
# 2026-10-13 之前，--zip-sorted 是把整棵樹的項目全部收集再一次排序（1,001,377 個項目用掉
# 1.79 GB）。現在它一次只對一個目錄開啟 libarchive 的走訪，於是有三件原本由 libarchive 負責的事
# 要在這裡檢查：
#   - 記憶體：必須跟著最大的單一目錄，而不是樹的大小；
#   - -h 與指回上層的連結：libarchive 是靠自己的堆疊擋下它們，而那個堆疊現在只有一層，所以改由
#     走訪帶著上層目錄；
#   - 開啟中的目錄：同時只能有一個，否則很深的樹會把 file descriptor 用完。
# 順序本身、以及執行期間變大的檔案，在 test_zip_fidelity.zsh。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,27p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
HERE="${script_path:h}"
ROOT="${HERE:h}"
POSIX=1
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) POSIX=0; : "${ST:=$ROOT/release/swift_tar.exe}" ;;
  *) : "${ST:=$ROOT/release/swift_tar}" ;;
esac
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }
same() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1"; fi; }

# Peak memory of a command, in zsh's own unit, which is the same for both sides of a
# comparison. / 一個命令的最大記憶體，單位由 zsh 決定，比較的兩邊相同。
peak() { local TIMEFMT='%M'; { time "$@" >/dev/null 2>/dev/null; } 2>&1 | tail -1; }

# ---- nested order ------------------------------------------------------------------------
# Directories inside directories, a name that sorts between a directory and its contents
# when whole paths are compared (`d.x` against `d/...`), and a name that is not ASCII. The
# tar path's listing is the reference.
# 目錄裡還有目錄；一個在比較整條路徑時會排進「目錄與其內容之間」的名稱（`d.x` 對 `d/...`）；
# 以及一個非 ASCII 的名稱。以 tar 路徑的清單為準。
NEST="$TMP/nest"
mkdir -p "$NEST/t/d/sub/deeper" "$NEST/t/d.x" "$NEST/t/d-x/in" "$NEST/t/中文" "$NEST/t/z/z/z"
for f in d/f d/sub/g d/sub/deeper/h d.x/f d-x/in/f "中文/檔.txt" z/z/z/leaf top a.txt; do
  print -r -- "$f" > "$NEST/t/$f"
done
( cd -q "$NEST" && "$ST" -c -f "$TMP/nest.tar" t ) >/dev/null 2>&1
"$ST" -t -f "$TMP/nest.tar" | sed 's,/$,,' > "$TMP/nest.tar.lst"
for codec in --zip --zip64; do
  rc=0; ( cd -q "$NEST" && "$ST" -c $codec --zip-sorted -f "$TMP/nest.zip" t ) >/dev/null 2>&1 || rc=$?
  eq "$codec nested: -c exits 0" 0 "$rc"
  "$ST" -t -f "$TMP/nest.zip" | sed 's,/$,,' > "$TMP/nest.zip.lst"
  same "$codec nested: members are in the tar path's order" "$TMP/nest.tar.lst" "$TMP/nest.zip.lst"
  # Two arguments are two walks, written in the order given.
  # 兩個引數是兩次走訪，依給定的順序寫出。
  ( cd -q "$NEST" && "$ST" -c $codec --zip-sorted -f "$TMP/nest2.zip" t/z t/d ) >/dev/null 2>&1
  "$ST" -t -f "$TMP/nest2.zip" | sed 's,/$,,' > "$TMP/nest2.lst"
  eq "$codec two arguments: the first argument's members come first" "t/z" "$(head -1 "$TMP/nest2.lst")"
  eq "$codec two arguments: the second argument follows the first's last member" \
     "t/z/z/z/leaf t/d" "$(sed -n '4,5p' "$TMP/nest2.lst" | tr '\n' ' ' | sed 's/ $//')"
  # --exclude leaves a directory out and everything under it.
  # --exclude 排除一個目錄與其下的一切。
  rc=0; ( cd -q "$NEST" && "$ST" -c $codec --zip-sorted --exclude sub -f "$TMP/nestx.zip" t ) >/dev/null 2>&1 || rc=$?
  eq "$codec --exclude: -c exits 0" 0 "$rc"
  grep -v '^t/d/sub' "$TMP/nest.tar.lst" > "$TMP/nestx.want"
  "$ST" -t -f "$TMP/nestx.zip" | sed 's,/$,,' > "$TMP/nestx.lst"
  same "$codec --exclude: the directory and what is under it are left out" "$TMP/nestx.want" "$TMP/nestx.lst"
  rm -f "$TMP/nest.zip" "$TMP/nest2.zip" "$TMP/nestx.zip"
done

# ---- memory ------------------------------------------------------------------------------
# 30,000 empty files in 150 directories. Holding every entry cost about 1.7 KB each, which
# here is some 50 MB on top of a run that otherwise peaks under 15 MB; holding one
# directory's names costs next to nothing. The default order is the yardstick, so the check
# does not depend on the unit or on the platform's baseline.
# 150 個目錄裡共 30,000 個空檔案。留住每個項目約各花 1.7 KB，在這裡是在原本最大值不到 15 MB 的
# 執行之上再多約 50 MB；只留一個目錄的名稱幾乎不花記憶體。以預設順序為基準，所以這項檢查不取決於
# 單位，也不取決於平台的基本用量。
MEM="$TMP/mem"
mkdir -p "$MEM/t"
for d in {001..150}; do
  mkdir "$MEM/t/d$d"
  ( cd -q "$MEM/t/d$d" && : > f{001..200} )
done
( cd -q "$MEM" && "$ST" -c -f "$TMP/mem.tar" t ) >/dev/null 2>&1
"$ST" -t -f "$TMP/mem.tar" | sed 's,/$,,' > "$TMP/mem.tar.lst"
eq "memory: the tree has 30,151 members" 30151 "$(wc -l < "$TMP/mem.tar.lst" | tr -d ' ')"
for codec in --zip --zip64; do
  ( cd -q "$MEM" && "$ST" -c $codec --zip-sorted -f "$TMP/mem.zip" t ) >/dev/null 2>&1
  "$ST" -t -f "$TMP/mem.zip" | sed 's,/$,,' > "$TMP/mem.zip.lst"
  same "$codec memory: 30,151 members are in the tar path's order" "$TMP/mem.tar.lst" "$TMP/mem.zip.lst"
  plain=$(cd -q "$MEM" && peak "$ST" -c $codec -f "$TMP/mem.zip" t)
  sorted=$(cd -q "$MEM" && peak "$ST" -c $codec --zip-sorted -f "$TMP/mem.zip" t)
  if [ "$plain" -gt 0 ] && [ "$sorted" -lt $((plain * 2)) ]; then
    ok "$codec memory: --zip-sorted peaks below twice the default ($sorted against $plain)"
  else
    bad "$codec memory: --zip-sorted peaks below twice the default ($sorted against $plain)"
  fi
  rm -f "$TMP/mem.zip"
done

if [ "$POSIX" = 1 ]; then
  # ---- links that lead back up, with -h ----------------------------------------------------
  # `loop` names the directory it is in, `up` the top of the tree, `todir` a sibling. With
  # -h each is followed; the first two lead back into directories the walk is already
  # inside and must stop. What the default order stores is the reference: the same
  # members, whichever way they are ordered.
  # `loop` 指向它所在的目錄，`up` 指向樹的頂端，`todir` 指向旁邊的目錄。加了 -h 每個都會被跟進去；
  # 前兩個會指回走訪已經身在其中的目錄，必須停下來。以預設順序存下的內容為準：成員相同，不論順序。
  LOOP="$TMP/loop"
  mkdir -p "$LOOP/t/d/sub" "$LOOP/t/e"
  print -r -- one > "$LOOP/t/d/f"
  print -r -- two > "$LOOP/t/d/sub/g"
  ln -s . "$LOOP/t/e/loop"
  ln -s .. "$LOOP/t/d/up"
  ln -s ../d "$LOOP/t/e/todir"
  ln -s ../d/f "$LOOP/t/e/tofile"
  ln -s nowhere "$LOOP/t/e/broken"
  for codec in --zip --zip64; do
    for h in "" -h; do
      label="$codec${h:+ $h} links"
      rc=0; ( cd -q "$LOOP" && "$ST" -c $codec $h -f "$TMP/loop.plain.zip" t ) >/dev/null 2>&1 || rc=$?
      eq "$label: the default order exits 0" 0 "$rc"
      rc=0; ( cd -q "$LOOP" && "$ST" -c $codec --zip-sorted $h -f "$TMP/loop.zip" t ) >/dev/null 2>"$TMP/loop.err" || rc=$?
      eq "$label: --zip-sorted exits 0" 0 "$rc"
      eq "$label: --zip-sorted says nothing on stderr" "" "$(cat "$TMP/loop.err")"
      "$ST" -t -f "$TMP/loop.plain.zip" | LC_ALL=C sort > "$TMP/loop.plain.lst"
      "$ST" -t -f "$TMP/loop.zip" | LC_ALL=C sort > "$TMP/loop.lst"
      same "$label: the same members as the default order" "$TMP/loop.plain.lst" "$TMP/loop.lst"
      rm -rf "$TMP/loop.out"; mkdir "$TMP/loop.out"
      "$ST" -x -f "$TMP/loop.zip" -C "$TMP/loop.out" >/dev/null 2>&1 || true
      if [ -z "$h" ]; then
        [ -L "$TMP/loop.out/t/e/loop" ] && ok "$label: a link is stored as a link" \
          || bad "$label: a link is stored as a link"
        eq "$label: a broken link keeps its target" nowhere "$(readlink "$TMP/loop.out/t/e/broken" || true)"
      else
        # Followed once, then stored as the link it is. / 跟進去一次，之後存成連結本身。
        [ -d "$TMP/loop.out/t/e/loop" ] && [ ! -L "$TMP/loop.out/t/e/loop" ] \
          && ok "$label: a link to its own directory is followed once" \
          || bad "$label: a link to its own directory is followed once"
        [ -L "$TMP/loop.out/t/e/loop/loop" ] && ok "$label: and is a link the second time round" \
          || bad "$label: and is a link the second time round"
        [ -L "$TMP/loop.out/t/d/up" ] && ok "$label: a link to the top of the tree is not followed" \
          || bad "$label: a link to the top of the tree is not followed"
        cmp -s "$LOOP/t/d/sub/g" "$TMP/loop.out/t/e/todir/sub/g" \
          && ok "$label: a link to another directory is stored as that directory" \
          || bad "$label: a link to another directory is stored as that directory"
        cmp -s "$LOOP/t/d/f" "$TMP/loop.out/t/e/tofile" && [ ! -L "$TMP/loop.out/t/e/tofile" ] \
          && ok "$label: a link to a file is stored as that file" \
          || bad "$label: a link to a file is stored as that file"
        eq "$label: a broken link stays a link" nowhere "$(readlink "$TMP/loop.out/t/e/broken" || true)"
      fi
      rm -f "$TMP/loop.zip" "$TMP/loop.plain.zip"
    done
  done

  # ---- one directory open at a time --------------------------------------------------------
  # 120 levels with 40 file descriptors allowed. A walk that left each level open on its way
  # down would need more than one per level.
  # 120 層，只允許 40 個 file descriptor。若往下走時每一層都留著不關，每層至少要用掉一個以上。
  DEEP="$TMP/deep"
  p="$DEEP/t"; for i in {1..120}; do p="$p/d"; done
  mkdir -p "$p"; print -r -- bottom > "$p/leaf"
  for codec in --zip --zip64; do
    rc=0; ( ulimit -n 40; cd -q "$DEEP" && "$ST" -c $codec --zip-sorted -f "$TMP/deep.zip" t ) >/dev/null 2>&1 || rc=$?
    eq "$codec deep: -c exits 0 with 40 file descriptors" 0 "$rc"
    eq "$codec deep: all 122 members are stored" 122 "$("$ST" -t -f "$TMP/deep.zip" | wc -l | tr -d ' ')"
    rm -f "$TMP/deep.zip"
  done
else
  echo "SKIP: link and file-descriptor cases (POSIX only)"
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
