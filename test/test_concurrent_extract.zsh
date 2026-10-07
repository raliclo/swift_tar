#!/usr/bin/env zsh
# test_concurrent_extract.zsh -- several `swift_tar -x -C <same root>` at once, each with a
# shard of one tree, must all succeed and together rebuild the tree exactly.
# test_concurrent_extract.zsh -- 多個 `swift_tar -x -C <同一根目錄>` 同時執行、各解一片同一棵
# 樹，必須全部成功，合起來恰好重建整棵樹。
#
#   ./test/test_concurrent_extract.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_concurrent_extract.zsh    # a specific binary
#   ROUNDS=30 SHARDS=12 ./test/test_concurrent_extract.zsh      # more pressure
#
# Asked for by M6-Multissh (2026-10-07), which will split a transfer into K swift_tar
# processes extracting into one root. The shards share parent directories, so every
# process races the others to create them: EEXIST from a parent made a moment earlier by
# another process must not be an error, and ensureDirectory's "clear a non-directory in
# the way" step must never remove what another process just wrote. Races do not show on
# every run, so each mode repeats ROUNDS times. File shards carry no directory entries --
# the shape multissh will produce -- and the directories travel in their own shard,
# extracted last, so their preserved mtimes land after every file.
#
# M6-Multissh 的請求（2026-10-07）：它會把一次傳輸分成 K 個 swift_tar 程序解到同一個根目錄。
# 各片共用上層目錄，所以每個程序都在和其他程序競爭建立它們：另一個程序剛建好的上層目錄所造成
# 的 EEXIST 不可報錯，ensureDirectory「清掉擋路的非目錄」那一步也絕不可刪掉另一個程序剛寫好的
# 東西。競態不是每次都出現，所以每種模式重複 ROUNDS 輪。檔案片不含目錄項目——正是 multissh 會
# 產生的形狀——目錄另成一片、最後才解，使保留的 mtime 落在所有檔案之後。
set -euo pipefail
zmodload zsh/stat

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,30p' "$script_path" | sed 's/^# \{0,1\}//'
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
ROUNDS=${ROUNDS:-10}
SHARDS=${SHARDS:-8}
SYS_TAR=${SYS_TAR:-tar}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# ---- the tree: 3 levels of shared parents, files at every level ----
# ---- 測試樹：三層共用的上層目錄，每一層都有檔案 ----
SRC="$TMP/src"
for a in a b c d; do for b in 1 2 3 4; do for c in x y z w; do
  mkdir -p "$SRC/$a/$b/$c"
  for f in 1 2 3; do head -c $(( 1000 + RANDOM )) /dev/urandom > "$SRC/$a/$b/$c/f$f.bin"; done
done; print -r -- "$a$b" > "$SRC/$a/$b/mid.txt"; done; print -r -- "$a" > "$SRC/$a/top.txt"; done
chmod 640 "$SRC/a/1/x/f1.bin"
# Fixed, old directory times, deepest first, so the check below can tell a preserved
# time from one the extraction left behind.
# 固定且久遠的目錄時間，由深至淺設定，使下方的檢查分得出「保留的時間」與「解出時留下的時間」。
for d in ${(On)$(cd "$SRC" && find . -mindepth 1 -type d)}; do touch -t 202001020304.05 "$SRC/$d"; done

FILES=(${(f)"$(cd "$SRC" && find . -type f | sed 's|^\./||' | sort)"})
DIRS=(${(f)"$(cd "$SRC" && find . -mindepth 1 -type d | sed 's|^\./||' | sort)"})

# ---- shards: file i goes to shard i % SHARDS; directories in their own shard ----
# ---- 分片：第 i 個檔案歸第 i % SHARDS 片；目錄另成一片 ----
make_shards() {  # <out dir> <codec flags...>
  local out=$1; shift
  mkdir -p "$out"
  local s i
  for (( s = 0; s < SHARDS; s++ )); do
    local part=()
    for (( i = s + 1; i <= ${#FILES}; i += SHARDS )); do part+=("${FILES[i]}"); done
    ( cd "$SRC" && "$ST" -c "$@" -f "$out/shard$s" "${part[@]}" ) >/dev/null 2>&1
  done
  ( cd "$SRC" && "$SYS_TAR" -cf "$out/dirs.tar" --no-recursion "${DIRS[@]}" ) >/dev/null 2>&1
}
make_shards "$TMP/plain"
make_shards "$TMP/zstd" --zstd

# Preconditions: file shards hold no directory entries, the directory shard holds every
# directory and nothing else. Otherwise the race being tested is not the one multissh has.
# 前提：檔案片不含目錄項目，目錄片含有全部目錄且僅含目錄。否則測到的就不是 multissh 會遇到的競態。
dirents=$("$ST" -t -f "$TMP/plain/shard0" 2>/dev/null | grep -c '/$' || true)
[ "$dirents" = 0 ] && ok "precondition: file shards carry no directory entries" \
  || bad "precondition: file shards carry no directory entries (got $dirents)"
ndirs=$("$ST" -t -f "$TMP/plain/dirs.tar" 2>/dev/null | wc -l | tr -d ' ')
[ "$ndirs" = "${#DIRS}" ] && ok "precondition: the directory shard lists all ${#DIRS} directories" \
  || bad "precondition: the directory shard lists all ${#DIRS} directories (got $ndirs)"

manifest() { ( cd "$1" && find . -type f | sort | xargs shasum -a 256 ) | shasum -a 256 | cut -c1-16; }
WANT=$(manifest "$SRC")
mode_of() { zstat -L +mode "$1" 2>/dev/null | awk '{printf "%o", $1 % 4096}'; }
mtime_of() { zstat -L +mtime "$1" 2>/dev/null || print -r -- absent; }

# run_round <archive dir> <-x flags...> ; sets RC_BAD (processes with rc != 0) and ERRS
# run_round <封存目錄> <-x 旗標...>；設定 RC_BAD（rc 非 0 的程序數）與 ERRS
run_round() {
  local arcs=$1; shift
  OUT="$TMP/out"; rm -rf "$OUT"; mkdir -p "$OUT"
  local pids=() s p rc
  for (( s = 0; s < SHARDS; s++ )); do
    "$ST" -x "$@" -f "$arcs/shard$s" -C "$OUT" >/dev/null 2>"$TMP/err$s" &
    pids+=($!)
  done
  RC_BAD=0
  for p in $pids; do rc=0; wait $p || rc=$?; (( rc == 0 )) || RC_BAD=$((RC_BAD + 1)); done
  ERRS=$(cat "$TMP"/err*(N) | head -3)
  # Directories last, as multissh plans. / 目錄最後解，照 multissh 的計畫。
  rc=0; "$ST" -x "$@" -f "$arcs/dirs.tar" -C "$OUT" >/dev/null 2>>"$TMP/err0" || rc=$?
  (( rc == 0 )) || RC_BAD=$((RC_BAD + 1))
}

check_mode() {  # <label> <archive dir> <-x flags...>
  local label=$1 arcs=$2; shift 2
  local r bad_rc=0 bad_err=0 bad_tree=0 first_err=""
  for (( r = 1; r <= ROUNDS; r++ )); do
    run_round "$arcs" "$@"
    (( RC_BAD == 0 )) || bad_rc=$((bad_rc + 1))
    if [ -n "$ERRS" ]; then bad_err=$((bad_err + 1)); [ -z "$first_err" ] && first_err=$ERRS; fi
    [ "$(manifest "$OUT")" = "$WANT" ] || bad_tree=$((bad_tree + 1))
  done
  (( bad_rc == 0 )) && ok "$label: every process exits 0 in $ROUNDS rounds" \
    || bad "$label: every process exits 0 in $ROUNDS rounds ($bad_rc rounds had a failure)"
  (( bad_err == 0 )) && ok "$label: nothing on stderr" \
    || bad "$label: nothing on stderr ($bad_err rounds; first: ${first_err//$'\n'/ | })"
  (( bad_tree == 0 )) && ok "$label: the tree is rebuilt exactly in every round" \
    || bad "$label: the tree is rebuilt exactly in every round ($bad_tree rounds differ)"
}

check_mode "--touch" "$TMP/plain" --touch
check_mode "preserve (default)" "$TMP/plain"
# Times after the last preserve round: a file keeps its own, a directory gets the one from
# the directory shard extracted last.
# 最後一輪保留模式後的時間：檔案保有自己的時間，目錄得到最後解出的目錄片中的時間。
[ "$(mtime_of "$OUT/a/1/x/f1.bin")" = "$(mtime_of "$SRC/a/1/x/f1.bin")" ] \
  && ok "preserve: a file keeps its archived mtime" || bad "preserve: a file keeps its archived mtime"
dir_ok=1
for d in a a/1 a/1/x d/4/w; do
  [ "$(mtime_of "$OUT/$d")" = "$(mtime_of "$SRC/$d")" ] || dir_ok=0
done
(( dir_ok )) && ok "preserve: directories get their archived mtimes from the last shard" \
  || bad "preserve: directories get their archived mtimes from the last shard"
check_mode "-p" "$TMP/plain" -p
[ "$(mode_of "$OUT/a/1/x/f1.bin")" = 640 ] && ok "-p: a file keeps its mode (640)" \
  || bad "-p: a file keeps its mode (640) (got $(mode_of "$OUT/a/1/x/f1.bin"))"
check_mode "zstd archives, --zstd-parallel --touch" "$TMP/zstd" --zstd-parallel --touch

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
