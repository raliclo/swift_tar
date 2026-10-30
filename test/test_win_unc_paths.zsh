#!/usr/bin/env zsh
# test/test_win_unc_paths.zsh -- -c and -x work through a UNC path (\\server\share\...) (Windows).
# test/test_win_unc_paths.zsh -- -c 與 -x 可經由 UNC 路徑（\\server\share\...）運作（Windows）。
#
#   ./test/test_win_unc_paths.zsh          run against release/swift_tar.exe / 以 release/swift_tar.exe 執行
#   ./test/test_win_unc_paths.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# winUcrtPath turned `\\server\share\x` into `\\?\\\server\share\x`, which names nothing, and
# winMakeDirectories built `\\?\server\share`. So `-x -C <UNC>` wrote no file (0.1.4 already), and
# once finding H sent winStat and the readers through winUcrtPath, `-c` from a share said "cannot
# stat" too (2026-10-30: 0.1.4 stored 4 members, ab1b4e9 none). The share used is the local admin
# share //localhost/C$, so no server is needed; the test SKIPs where it is not reachable. The `..`
# cases pin that `..` resolves inside the share, and the cwd case covers winProcessCwd being UNC.
# winUcrtPath 把 `\\server\share\x` 轉成什麼也不指向的 `\\?\\\server\share\x`，winMakeDirectories 則組出
# `\\?\server\share`。於是 `-x -C <UNC>` 一個檔案都寫不出（0.1.4 即如此）；發現 H 讓 winStat 與讀取
# 函式改走 winUcrtPath 之後，從共用資料夾 `-c` 也回報「cannot stat」（2026-10-30：0.1.4 收入 4 個成員，
# ab1b4e9 為 0）。所用的共用是本機管理共用 //localhost/C$，不需要伺服器；連不到時 SKIP。`..` 案例釘住
# `..` 在共用內解析，cwd 案例涵蓋 winProcessCwd 為 UNC 的情形。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) printf '%s\n' "SKIP: UNC paths are a Windows form / UNC 路徑是 Windows 的形式" \
                   "PASS: 0  FAIL: 0  SKIP: 1"; exit 0 ;;
esac

ROOT="${script_path:h:h}"
ST="${ST:-$ROOT/release/swift_tar.exe}"
[[ -x $ST ]] || { printf '%s\n' "error: build first -- missing $ST / 請先建置" >&2; exit 1 }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# The same directory, seen through the admin share: C:/x/y -> //localhost/C$/x/y.
# 同一個目錄，經由管理共用看：C:/x/y -> //localhost/C$/x/y。
win=$(cygpath -m "$TMP")
U="//localhost/${win[1]}\$${win[3,-1]}"
if [[ ${win[2]} != : || ! -d $U ]]; then
  printf '%s\n' "SKIP: $U is not reachable (admin share off?) / 連不到 $U（管理共用未開？）" "PASS: 0  FAIL: 0  SKIP: 1"
  exit 0
fi

pass=0 fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }

mkdir -p $TMP/src/u/sub
printf 'a' > $TMP/src/u/a.txt
printf 'b' > $TMP/src/u/sub/b.txt

# created <label> <archive> -- -c exited 0 and the archive extracts locally to the two files.
# created <標籤> <封存>——-c 以 0 結束，且封存在本機解出這兩個檔案。
created() {
  if (( rc != 0 )); then bad "$1: -c exits 0 (got $rc)"; cat $TMP/err; return; fi
  rm -rf -- $TMP/chk; mkdir $TMP/chk
  "$ST" -x -f $2 -C $TMP/chk </dev/null
  [[ $(<$TMP/chk/u/a.txt) == a && $(<$TMP/chk/u/sub/b.txt) == b ]] \
    && ok "$1" || bad "$1: members missing or wrong"
}
# extracted <label> <dir> -- -x exited 0 and <dir> (local view) holds the two files.
# extracted <標籤> <目錄>——-x 以 0 結束，且 <目錄>（本機視角）內有這兩個檔案。
extracted() {
  if (( rc != 0 )); then bad "$1: -x exits 0 (got $rc)"; cat $TMP/err; return; fi
  [[ -f $2/u/a.txt && $(<$2/u/a.txt) == a && $(<$2/u/sub/b.txt) == b ]] \
    && ok "$1" || bad "$1: files missing or wrong"
}

rc=0; "$ST" -c -f $TMP/c1.tar -C "$U/src" u 2>$TMP/err </dev/null || rc=$?
created "-c -C <UNC>" $TMP/c1.tar
rc=0; "$ST" -c -f $TMP/c2.tar -C "$U/src/u/.." u 2>$TMP/err </dev/null || rc=$?
created "-c -C <UNC>/u/.." $TMP/c2.tar
rc=0; ( cd "$U/src" && "$ST" -c -f $TMP/c3.tar u ) 2>$TMP/err </dev/null || rc=$?
created "-c with a UNC working directory" $TMP/c3.tar

mkdir -p $TMP/d1 $TMP/d2/x $TMP/d3
rc=0; "$ST" -x -f $TMP/c1.tar -C "$U/d1" 2>$TMP/err </dev/null || rc=$?
extracted "-x -C <UNC>" $TMP/d1
rc=0; "$ST" -x -f $TMP/c1.tar -C "$U/d2/x/.." 2>$TMP/err </dev/null || rc=$?
extracted "-x -C <UNC>/x/.." $TMP/d2
rc=0; ( cd "$U/d3" && "$ST" -x -f $TMP/c1.tar ) 2>$TMP/err </dev/null || rc=$?
extracted "-x with a UNC working directory" $TMP/d3

printf 'PASS: %d  FAIL: %d  SKIP: 0\n' $pass $fail
(( fail == 0 ))
