#!/usr/bin/env zsh
# test_bridge_errors.zsh -- every libarchive error message in the ZIP bridge goes through archive_reason.
# test_bridge_errors.zsh -- ZIP 橋接層的每個 libarchive 錯誤訊息都經過 archive_reason。
#
#   ./test/test_bridge_errors.zsh                               # libarchive_zip_bridge.c
#   SRC=/path/to/libarchive_zip_bridge.c ./test/test_bridge_errors.zsh   # another copy
#
# archive_error_string returns NULL when libarchive set no message, and a status below ARCHIVE_OK
# does not promise one. Eleven sites handed it straight to printf's %s, which is undefined
# behaviour on NULL (glibc prints "(null)", other C runtimes may crash); the 2026-10-30 review
# found one, and the rest had the same shape. A NULL message cannot be provoked from the command
# line without injecting a fault into libarchive, so this checks the source instead: the only
# call left is inside archive_reason, which never returns NULL. A new direct call fails here.
# 沒有設定訊息時 archive_error_string 回傳 NULL，而低於 ARCHIVE_OK 的狀態並不保證有訊息。原本有
# 11 處把它直接交給 printf 的 %s，對 NULL 是未定義行為（glibc 印出 "(null)"，其他 C 執行環境可能
# 崩潰）；2026-10-30 審查指出一處，其餘同形。不在 libarchive 內注入錯誤就無法從命令列造出 NULL
# 訊息，所以這裡改查原始碼：唯一剩下的呼叫在 archive_reason 裡，而它絕不回傳 NULL。新增一處
# 直接呼叫就會在這裡失敗。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
ROOT="${script_path:h:h}"
SRC="${SRC:-$ROOT/libarchive_zip_bridge.c}"
[ -r "$SRC" ] || { echo "error: missing $SRC" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Code only: what lies inside /* ... */ is dropped, tracked across lines. Not "a line starting
# with *": that is also `*msg = archive_error_string(a);`, which the first version of this test
# skipped as a comment and passed 4/4 (2026-10-31 review).
# 只看程式碼：/* ... */ 之內的部分跨行追蹤並捨去。不用「以 * 開頭的行」：那也包括
# `*msg = archive_error_string(a);`，本測試第一版把它當成註解略過，照樣 4/4 通過（2026-10-31 審查）。
calls=() n=0 def=0 in_comment=0
while IFS= read -r line; do
  n=$((n + 1))
  code="" rest=$line
  while [ -n "$rest" ]; do
    if (( in_comment )); then
      [[ $rest == *'*/'* ]] || break
      rest=${rest#*'*/'}; in_comment=0
    elif [[ $rest == *'/*'* ]]; then
      code+=${rest%%'/*'*}; rest=${rest#*'/*'}; in_comment=1
    else
      code+=$rest; rest=""
    fi
  done
  [[ $code == *'static const char *archive_reason('* ]] && def=$n
  [[ $code == *'archive_error_string('* ]] && calls+=($n)
done < "$SRC"

[ "$def" -gt 0 ] && ok "archive_reason is defined" || bad "archive_reason is defined"
[ "${#calls}" -eq 1 ] && ok "archive_error_string is called in one place" \
  || bad "archive_error_string is called in one place (lines: ${calls[*]:-none})"
if [ "${#calls}" -eq 1 ] && [ "$def" -gt 0 ] && (( calls[1] > def && calls[1] - def <= 3 )); then
  ok "that one call is inside archive_reason"
else bad "that one call is inside archive_reason (def line $def, calls ${calls[*]:-none})"; fi
grep -qF 'return detail != NULL ? detail : "unknown libarchive error";' "$SRC" \
  && ok "archive_reason falls back to a message instead of NULL" \
  || bad "archive_reason falls back to a message instead of NULL"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" = 0 ]
