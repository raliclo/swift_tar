#!/usr/bin/env zsh
# test/test_win_reparse_read.zsh -- how -c reads Windows reparse points: exact linknames, one tag lookup per -h hop.
# test/test_win_reparse_read.zsh -- -c 如何讀取 Windows reparse point：linkname 一字不差、-h 每跳只查一次 tag。
#
#   ./test/test_win_reparse_read.zsh          run against release/swift_tar.exe / 以 release/swift_tar.exe 執行
#   ./test/test_win_reparse_read.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# Two guards from the 2026-10-30 review:
#   item 9 -- winReadSymlinkTarget bounded its reads by the 16 KiB buffer, not the bytes
#     DeviceIoControl returned, so a corrupt length could pull the zero fill into the linkname.
#     A corrupt reparse buffer cannot be planted without a driver, so what is pinned here is the
#     other side: with the bound now `returned`, a DANGLING native symlink and a dangling LX
#     symlink -- the two kinds that reach winReadSymlinkTarget, since destinationOfSymbolicLink
#     returns nil for both -- still store their exact target, byte for byte.
#   item 8 -- winStatFollowing asked FindFirstFileW for the tag again on every hop although winStat
#     had just read it. The -h behaviour is test_dereference.zsh case 5; this checks the source so
#     the second lookup cannot quietly return.
# 2026-10-30 審查的兩道防線：
#   第 9 項——winReadSymlinkTarget 以 16 KiB 緩衝區為讀取邊界，而非 DeviceIoControl 實際回傳的位元組
#     數，損壞的長度可能把填零的部分讀進 linkname。沒有驅動程式種不出損壞的 reparse buffer，故此處
#     釘住的是另一面：邊界改為 `returned` 之後，dangling 的原生 symlink 與 dangling 的 LX symlink——會
#     走到 winReadSymlinkTarget 的正是這兩種，destinationOfSymbolicLink 對兩者都回 nil——仍逐位元組
#     存下正確目標。
#   第 8 項——winStatFollowing 每一跳都再問一次 FindFirstFileW 取 tag，儘管 winStat 剛讀過。-h 的行為
#     由 test_dereference.zsh 第 5 案涵蓋；這裡檢查原始碼，讓第二次查詢不會悄悄回來。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT="${script_path:h:h}"
pass=0 fail=0 skip=0
ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }
skipc(){ printf 'SKIP: %s\n' "$1"; skip=$((skip + 1)) }

# Item 8, on every platform: the source is the same file everywhere.
# 第 8 項，各平台皆跑：原始碼在哪裡都是同一份。
body=$(sed -n '/^private func winStatFollowing(/,/^}/p' "$ROOT/swift_tar.swift")
if [[ -z $body ]]; then
  bad "winStatFollowing found in swift_tar.swift"
elif [[ $body == *'winReparseTag('* ]]; then
  bad "winStatFollowing reuses winStat's tag instead of calling winReparseTag again"
else
  ok "winStatFollowing reuses winStat's tag instead of calling winReparseTag again"
fi

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) skipc "reparse buffers exist only on Windows / reparse buffer 只存在於 Windows"
     printf 'PASS: %d  FAIL: %d  SKIP: %d\n' $pass $fail $skip
     (( fail == 0 )); exit ;;
esac

ST="${ST:-$ROOT/release/swift_tar.exe}"
[[ -x $ST ]] || { printf '%s\n' "error: build first -- missing $ST / 請先建置" >&2; exit 1 }
GT="${GNU_TAR:-$(cygpath -u "${PROGRAMFILES:-C:/Program Files}")/Git/usr/bin/tar.exe}"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/src"

# The stored linkname, read by GNU tar (an independent reader) from `name -> target`.
# 存下的 linkname，由 GNU tar（獨立的讀取端）從 `name -> target` 讀出。
linkname_of() {
  local line
  line=$(cd "$TMP" && "$GT" -tvf "$1" "$2") </dev/null
  printf '%s' "${line#* $2 -> }"
}
check_link() {   # check_link <label> <member> <want>
  local rc=0 got
  ( cd "$TMP/src" && "$ST" -c -f "../$2.tar" "$2" ) </dev/null || rc=$?
  [[ $rc == 0 ]] || { bad "$1: -c exits 0 (got $rc)"; return }
  got=$(linkname_of "$2.tar" "$2")
  [[ $got == "$3" ]] && ok "$1: linkname stored exactly" || bad "$1: linkname stored exactly (got [$got], want [$3])"
}

if [[ ! -x $GT ]]; then
  skipc "no GNU tar at $GT (set GNU_TAR) / 找不到 GNU tar（請設定 GNU_TAR）"
else
  # cmd's mklink, relative names only (see test_dereference.zsh for what cygpath does here).
  # The `|| true` is deliberate: without Developer Mode mklink fails, and the -L test below
  # turns that into a SKIP with the reason instead of an abort.
  # 用 cmd 的 mklink，只用相對名稱（cygpath 在此會做什麼見 test_dereference.zsh）。`|| true` 是刻意的：
  # 沒有開發者模式時 mklink 會失敗，下方的 -L 檢查把它轉成附原因的 SKIP，而不是中止。
  ( cd "$TMP/src" && cmd.exe //c mklink nat missing_native ) </dev/null >/dev/null 2>&1 || true
  if [[ -L $TMP/src/nat ]]; then
    check_link "dangling native symlink" nat missing_native
  else
    skipc "dangling native symlink: mklink needs Developer Mode / mklink 需要開發者模式"
  fi

  # wsl.exe makes a real LX symlink; the cwd is inherited, so no path crosses (bugs.md trap #2).
  # The `|| true` is deliberate: without WSL there is no LX link, reported as a SKIP below.
  # wsl.exe 建的是真正的 LX symlink；cwd 由繼承而來，沒有路徑跨過去（bugs.md 陷阱 #2）。`|| true`
  # 是刻意的：沒有 WSL 就沒有 LX 連結，由下方以 SKIP 回報。
  if (( $+commands[wsl.exe] )); then
    ( cd "$TMP/src" && MSYS2_ARG_CONV_EXCL='*' wsl.exe -- ln -s missing_lx_target lx ) </dev/null >/dev/null 2>&1 || true
  fi
  if [[ -L $TMP/src/lx ]]; then
    check_link "dangling LX symlink" lx missing_lx_target
  else
    skipc "dangling LX symlink: needs wsl.exe / 需要 wsl.exe"
  fi
fi

printf 'PASS: %d  FAIL: %d  SKIP: %d\n' $pass $fail $skip
(( fail == 0 ))
