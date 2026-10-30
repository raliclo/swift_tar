#!/usr/bin/env zsh
# test/test_win_mtime_paths.zsh -- -x restores directory mtimes past MAX_PATH and on reserved names (Windows).
# test/test_win_mtime_paths.zsh -- -x 對超過 MAX_PATH 與保留名稱的目錄也還原 mtime（Windows）。
#
#   ./test/test_win_mtime_paths.zsh          run against release/swift_tar.exe / 以 release/swift_tar.exe 執行
#   ./test/test_win_mtime_paths.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# winSetPathMtime opened its target with the raw path, not winUcrtPath's `\\?\` form, so a
# directory whose absolute path passed MAX_PATH, or one named `con`, kept extraction time while
# -x exited 0 and said nothing -- the directory pass ignores a failed setter by design. Measured
# 2026-10-30 (review item 2): `plain` came back 1970-01-02, `con` and the 200-character directory
# came back as "now". `plain` stays as the control: a setter that failed everywhere would fail it.
# The fixture is made by GNU tar, because swift_tar -c cannot yet stat a directory named `con`.
# winSetPathMtime 以原始路徑開啟目標，而非 winUcrtPath 的 `\\?\` 形式，於是絕對路徑超過 MAX_PATH 的
# 目錄、或名為 `con` 的目錄，都留著解出當下的時間，-x 卻以 0 結束且不出聲——目錄階段刻意忽略設定失敗。
# 2026-10-30 實測（審查第 2 項）：`plain` 還原為 1970-01-02，`con` 與 200 字元的目錄則是「現在」。
# `plain` 保留為對照組：一個處處失敗的設定函式會在它身上失敗。測資以 GNU tar 產生，因為 swift_tar -c
# 目前還讀不到名為 `con` 的目錄。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) printf '%s\n' "SKIP: MAX_PATH and reserved names are Windows rules / MAX_PATH 與保留名稱是 Windows 的規則" \
                   "PASS: 0  FAIL: 0  SKIP: 1"; exit 0 ;;
esac

ROOT="${script_path:h:h}"
ST="${ST:-$ROOT/release/swift_tar.exe}"
[[ -x $ST ]] || { printf '%s\n' "error: build first -- missing $ST / 請先建置" >&2; exit 1 }
GT="${GNU_TAR:-$(cygpath -u "${PROGRAMFILES:-C:/Program Files}")/Git/usr/bin/tar.exe}"
if [[ ! -x $GT ]]; then
  printf '%s\n' "SKIP: no GNU tar at $GT (set GNU_TAR) / 找不到 GNU tar（請設定 GNU_TAR）" "PASS: 0  FAIL: 0  SKIP: 1"
  exit 0
fi
zmodload -F zsh/stat b:zstat

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0 fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }

# 201 characters, twice: the inner directory's absolute path is past MAX_PATH from any -C.
# 201 個字元、兩層：無論 -C 在哪，內層目錄的絕對路徑都超過 MAX_PATH。
long=$(printf 'a%.0s' {1..200})x
mkdir -p "$TMP/src/con" "$TMP/src/plain" "$TMP/src/$long/$long"
for d in con plain "$long/$long"; do printf 'hi' > "$TMP/src/$d/f.txt"; done
touch -d @86400 "$TMP/src/con" "$TMP/src/plain" "$TMP/src/$long" "$TMP/src/$long/$long"
# A relative -f: Git's GNU tar has its own MSYS root, so this shell's /tmp/... names another place.
# -f 用相對路徑：Git 的 GNU tar 有自己的 MSYS 根目錄，本 shell 的 /tmp/... 在它那裡是別處。
( cd "$TMP/src" && "$GT" --format=posix -cf ../a.tar con plain "$long" ) </dev/null

mkdir "$TMP/dest"
rc=0; ( cd "$TMP/dest" && "$ST" -x -f "$TMP/a.tar" ) </dev/null || rc=$?
[[ $rc == 0 ]] && ok "-x exits 0" || bad "-x exits 0 (got $rc)"

check_mtime() {
  local label=$1 dir=$2 got
  got=$(zstat +mtime -- "$TMP/dest/$dir")
  [[ $got == 86400 ]] && ok "$label: directory mtime restored" \
                      || bad "$label: directory mtime restored (got $got, want 86400)"
}
check_mtime "plain (control)" plain
check_mtime "reserved name con" con
check_mtime "201-char directory" "$long"
check_mtime "path past MAX_PATH" "$long/$long"
for d in con plain "$long/$long"; do
  [[ $(<"$TMP/dest/$d/f.txt") == hi ]] && ok "${d[1,12]}/f.txt extracted" || bad "${d[1,12]}/f.txt extracted"
done

printf 'PASS: %d  FAIL: %d  SKIP: 0\n' $pass $fail
(( fail == 0 ))
