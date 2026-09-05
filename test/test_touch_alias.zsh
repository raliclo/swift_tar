#!/usr/bin/env zsh
# test/test_touch_alias.zsh -- verify `-m` behaves as the short form of `--touch`.
# test/test_touch_alias.zsh -- 驗證 `-m` 的行為等同 `--touch` 的短寫。
#
#   ./test/test_touch_alias.zsh          run the suite against release/swift_tar
#                                        以 release/swift_tar 執行測試
#   ./test/test_touch_alias.zsh --help   print this synopsis and exit
#                                        印出本說明後結束
set -uo pipefail

# `-m` 是 `--touch` 的短寫，如同其他每一個 tar。
#
# swift_tar 早就有 `--touch`，語意也與 GNU 相同；缺的只是短寫。於是伸手去按那個大家都會
# 按的鍵的呼叫端，得到的是「unknown option -m」——來自一個本來就會照做的工具。
#
# 這個測試看的是行為而不是「有沒有被接受」。只斷言 `-m` 不再報未知選項，會讓一個「接受
# 之後什麼也不做」的實作照樣通過，而那正是這種別名最容易出的錯。
#
# `-m` is the short form of `--touch`, as in every other tar.
#
# swift_tar has had `--touch`, with GNU's semantics, all along; only the short
# form was missing. So a caller reaching for the key everyone reaches for got
# "unknown option -m" from a tool that already did exactly what was asked.
#
# This test looks at behaviour rather than acceptance. Asserting only that `-m`
# no longer reports an unknown option would pass an implementation that accepts
# the flag and then ignores it, which is the way an alias most easily goes wrong.

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,8p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

script_dir=${script_path:h}
root=${script_dir:h}
cd "$root"

tar=release/swift_tar
[[ $(uname -s) == *NT* ]] && tar=release/swift_tar.exe
[[ -x $tar ]] || { print -u2 -- "找不到 $tar；請先建置 / missing $tar"; exit 1 }

failures=0
check() {
  if [[ $1 == $2 ]]; then
    print -- "  ok   $3"
  else
    print -- "  FAIL $3 (expected $1, got $2)"
    (( failures += 1 ))
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar_abs=$root/$tar

mkdir -p "$work/src"
print -- x > "$work/src/old.txt"
# 一個久遠到不可能與「現在」相撞的 mtime：若兩者可能相同，這個測試就分不出還原與不還原。
# An mtime old enough that it cannot collide with "now": if the two could match,
# the test could not tell restoring from not restoring.
touch -t 202001010000 "$work/src/old.txt"

# 一個指向同目錄檔案的符號連結，帶著同樣久遠的 mtime。連結自身的 mtime 曾是解壓唯一
# 重現不出來的東西：一般檔走 futimens、目錄有收尾、FIFO 有自己的分支，唯獨連結建完就
# 結束，於是停在「現在」。這在兩次解壓相隔數分鐘時才顯形——lz4bench 的 manifest 比對
# 因此把兩個 codec 讀成不一致，而它們其實一模一樣。
# A symlink carrying the same old mtime. Its own mtime was the one thing an
# extraction could not reproduce: regular files go through futimens, directories
# get a final pass, FIFOs have their own branch, but a link was created and left
# at "now". It only shows when two extractions are minutes apart, which is how
# lz4bench's manifest comparison came to read two identical codecs as disagreeing.
ln -s old.txt "$work/src/link.txt" 2>/dev/null
touch -h -t 202001010000 "$work/src/link.txt" 2>/dev/null
# MSYS 未設 winsymlinks 時 `ln -s` 會成功卻產生副本；BusyBox 的 touch 也可能沒有 -h。
# 兩者都讓這組案例失去意義而非失敗，故以實測決定是否執行。
# ln -s can succeed while producing a copy on MSYS, and BusyBox touch may lack
# -h. Either makes these cases meaningless rather than failing, so they are
# gated on what actually happened.
link_ok=0
if [[ -L "$work/src/link.txt" ]]; then
  zmodload zsh/stat 2>/dev/null
  local -A probe
  if zstat -L -F '%Y' -H probe +mtime -- "$work/src/link.txt" 2>/dev/null; then
    [[ ${probe[mtime]} == 2020 ]] && link_ok=1
  fi
fi

( cd "$work" && "$tar_abs" -c --zstd -f a.tzst src ) 2>/dev/null

now_year=$(date +%Y)

# mtime 由 zsh 內建的 zsh/stat 模組讀取，不呼叫外部 stat。原本這裡先試 GNU 的
# `stat -c '%y'`，失敗再退回 BSD 的 `stat -f '%Sm'`——那涵蓋了 Linux 與 macOS，卻涵蓋不了
# 「沒有 stat」這第三種情況：Buildroot／BusyBox 的 guest 的 applet 清單裡根本沒有 stat，
# 於是兩個分支都靜默失敗，函式回傳空字串，而報告寫著 `expected 2020, got `，看起來像
# swift_tar 沒有還原 mtime。zstat 內建於 zsh，且 `-F '%Y'` 直接給出年份，連兩種格式字串
# 的差異都一併消失。
#
# The mtime comes from zsh's own zsh/stat module rather than an external stat.
# This used to try GNU's `stat -c '%y'` and fall back to BSD's `stat -f '%Sm'`,
# which covers Linux and macOS but not the third case: the Buildroot/BusyBox
# guest has no stat in its applet list at all, so both branches failed silently,
# the function returned an empty string, and the report read `expected 2020,
# got ` -- which looks like swift_tar failing to restore the mtime. zstat is
# built into zsh and `-F '%Y'` yields the year directly, so the two format
# dialects stop mattering as well.
zmodload zsh/stat

extract_year() {  # <旗標...> -> 解出檔案的 mtime 年份
  rm -rf "$work/out"; mkdir -p "$work/out"
  if ! ( cd "$work/out" && "$tar_abs" -x "$@" --zstd -f ../a.tzst ) >/dev/null 2>&1; then
    print -- "EXTRACT_FAILED"
    return
  fi
  local -A entry
  zstat -F '%Y' -H entry +mtime -- "$work/out/src/old.txt" 2>/dev/null || {
    print -- "STAT_FAILED"
    return
  }
  print -- "${entry[mtime]}"
}

print -- "swift_tar -m／--touch 別名 / the -m alias (archived mtime 2020, now $now_year):"

check "2020" "$(extract_year)" \
  "預設仍還原封存的 mtime / the default still restores the archived mtime"
check "$now_year" "$(extract_year --touch)" \
  "--touch 不還原 / --touch does not restore"
check "$now_year" "$(extract_year -m)" \
  "-m 與 --touch 行為相同 / -m behaves as --touch"
check "$now_year" "$(extract_year -m --touch)" \
  "兩者並用不衝突 / the two together do not conflict"

# 連結自身的 mtime。zstat 必須加 -L，否則它讀的是目標檔——而目標檔的 mtime 一直都是
# 對的，所以少了 -L 這組案例在修好之前就會通過，什麼也證明不了。
# The link's own mtime. zstat needs -L or it reads the target, whose mtime was
# always correct -- without it these cases would have passed before the fix and
# proved nothing.
extract_link_year() {
  rm -rf "$work/out"; mkdir -p "$work/out"
  if ! ( cd "$work/out" && "$tar_abs" -x "$@" --zstd -f ../a.tzst ) >/dev/null 2>&1; then
    print -- "EXTRACT_FAILED"
    return
  fi
  local -A entry
  zstat -L -F '%Y' -H entry +mtime -- "$work/out/src/link.txt" 2>/dev/null || {
    print -- "STAT_FAILED"
    return
  }
  print -- "${entry[mtime]}"
}

if (( link_ok )); then
  check "2020" "$(extract_link_year)" \
    "符號連結自身的 mtime 也還原 / a symlink's own mtime is restored too"
  check "$now_year" "$(extract_link_year --touch)" \
    "--touch 對連結同樣不還原 / --touch does not restore it either"
else
  print -- "  skip 本環境無法建立帶 mtime 的真符號連結 / no real symlink with a settable mtime here"
fi

# 未知選項的檢查本身必須仍然有效：這個別名擴大的是清單，不是把檢查關掉。
# The unknown-option check must still work: this alias widens the list, it does
# not switch the check off.
unknown=$( "$tar_abs" -x -M --zstd -f "$work/a.tzst" 2>&1 >/dev/null )
if [[ $unknown == *"unknown option -M"* ]]; then
  print -- "  ok   未知短選項仍被拒 / an unknown short option is still rejected"
else
  print -- "  FAIL 未知短選項未被拒 / an unknown short option was not rejected"
  print -- "       實際 / got: $unknown"
  (( failures += 1 ))
fi

print -- ""
if (( failures == 0 )); then
  print -- "通過 / PASS: -m alias"
else
  print -u2 -- "失敗 / FAIL: $failures check(s)"
fi
exit $(( failures != 0 ))
