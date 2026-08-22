#!/usr/bin/env zsh
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

script_dir=${0:A:h}
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
( cd "$work" && "$tar_abs" -c --zstd -f a.tzst src ) 2>/dev/null

now_year=$(date +%Y)

extract_year() {  # <旗標...> -> 解出檔案的 mtime 年份
  rm -rf "$work/out"; mkdir -p "$work/out"
  if ! ( cd "$work/out" && "$tar_abs" -x "$@" --zstd -f ../a.tzst ) >/dev/null 2>&1; then
    print -- "EXTRACT_FAILED"
    return
  fi
  local stamp
  if stamp=$(stat -c '%y' "$work/out/src/old.txt" 2>/dev/null); then
    print -- "${stamp%%-*}"
  else
    stat -f '%Sm' -t '%Y' "$work/out/src/old.txt" 2>/dev/null
  fi
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
