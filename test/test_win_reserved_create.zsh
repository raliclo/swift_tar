#!/usr/bin/env zsh
# test/test_win_reserved_create.zsh -- -c stores files and directories with reserved DOS names (Windows).
# test/test_win_reserved_create.zsh -- -c 能收入以 DOS 保留名稱命名的檔案與目錄（Windows）。
#
#   ./test/test_win_reserved_create.zsh          run against release/swift_tar.exe / 以 release/swift_tar.exe 執行
#   ./test/test_win_reserved_create.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# winStat, the directory listing and the file readers passed the raw path to Foundation, which
# resolves a bare `con`/`aux`/`nul`, and `nul` under any directory, to the DOS device. So
# `-c nul`, `-c con` or a walk reaching `sub/nul` said "cannot stat" and exited 1 for a file that
# exists (2026-10-30 review, finding H); `top/con` and `top/aux` worked, because Windows 11
# reserves only `nul` past the first component. `plain` is the control. big/nul is over the
# 1 MiB prefetch limit, so it is read through openContents rather than readSmallRegularFile.
# `pdir/` and `con/` pin the first version of that fix: winUcrtPath kept the empty segment of
# `pdir//f.txt`, which `\\?\` does not normalise, so `-c pdir/` left every file out as "cannot open"
# -- caught by test_blind_findings, not by this test, which had no trailing slash.
# winStat、目錄列舉與檔案讀取都把原始路徑交給 Foundation，而它會把裸的 `con`／`aux`／`nul`，以及
# 任何目錄下的 `nul`，解析成 DOS 裝置。於是 `-c nul`、`-c con` 或走訪到 `sub/nul` 時，對存在的檔案
# 回報「cannot stat」並以 1 結束（2026-10-30 審查，發現 H）；`top/con` 與 `top/aux` 正常，因為
# Windows 11 在第一段之後只保留 `nul`。`plain` 是對照組。big/nul 超過 1 MiB 的預讀上限，故經
# openContents 而非 readSmallRegularFile 讀取。`pdir/` 與 `con/` 釘住該修正的第一版：winUcrtPath
# 保留了 `pdir//f.txt` 的空段落，而 `\\?\` 不做正規化，於是 `-c pdir/` 把每個檔案都以「cannot open」
# 略過——是 test_blind_findings 抓到的，不是本測試，因為本測試原本沒有結尾斜線。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) printf '%s\n' "SKIP: reserved DOS names are a Windows rule / DOS 保留名稱是 Windows 的規則" \
                   "PASS: 0  FAIL: 0  SKIP: 1"; exit 0 ;;
esac

ROOT="${script_path:h:h}"
ST="${ST:-$ROOT/release/swift_tar.exe}"
[[ -x $ST ]] || { printf '%s\n' "error: build first -- missing $ST / 請先建置" >&2; exit 1 }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0 fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }

# The MSYS shell creates these names without trouble: it goes through NT paths.
# MSYS shell 建立這些名稱毫無困難：它走的是 NT 路徑。
src=$TMP/src
mkdir -p $src/con $src/nul $src/sub $src/big $src/pdir
printf 'd' > $src/pdir/f.txt
printf 'c' > $src/con/f.txt
printf 'n' > $src/nul/g.txt
printf 'a' > $src/aux
printf 's' > $src/sub/nul
printf 'p' > $src/plain
head -c 3000000 /dev/urandom > $TMP/big.bin
cp $TMP/big.bin $src/big/nul

# create <label> <member...> -- archive from inside src/, then extract into a fresh out/.
# create <標籤> <成員...>——在 src/ 內建立封存，再解到全新的 out/。
create() {
  local label=$1; shift
  rm -rf -- $TMP/out; mkdir $TMP/out
  rc=0; ( cd $src && "$ST" -c -f $TMP/a.tar "$@" ) 2>$TMP/err </dev/null || rc=$?
  (( rc == 0 )) && ok "$label: -c exits 0" || { bad "$label: -c exits 0 (got $rc)"; cat $TMP/err }
  "$ST" -x -f $TMP/a.tar -C $TMP/out </dev/null
}
# same <label> <relative path> <want> -- the extracted file holds <want>.
# same <標籤> <相對路徑> <預期>——解出的檔案內容為 <預期>。
same() {
  [[ -f $TMP/out/$2 && $(<$TMP/out/$2) == $3 ]] && ok "$1: $2 round-trips" || bad "$1: $2 round-trips"
}

create "plain (control)" plain;   same "plain (control)" plain p
create "bare aux" aux;            same "bare aux" aux a
create "bare con directory" con;  same "bare con directory" con/f.txt c
create "bare nul directory" nul;  same "bare nul directory" nul/g.txt n
create "nul under a directory" sub/nul; same "nul under a directory" sub/nul s
create "trailing slash" pdir/;    same "trailing slash" pdir/f.txt d
create "con with trailing slash" con/; same "con with trailing slash" con/f.txt c
create "walk from ." .
same walk plain p; same walk aux a; same walk con/f.txt c; same walk nul/g.txt n; same walk sub/nul s
create "3 MB nul (not prefetched)" big
cmp -s $TMP/out/big/nul $TMP/big.bin && ok "3 MB nul: bytes identical" || bad "3 MB nul: bytes identical"

printf 'PASS: %d  FAIL: %d  SKIP: 0\n' $pass $fail
(( fail == 0 ))
