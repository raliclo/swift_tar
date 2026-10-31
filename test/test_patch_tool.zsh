#!/usr/bin/env zsh
# test/test_patch_tool.zsh -- patch/tool.zsh finds Git's patch under %PROGRAMFILES% wherever it is (Windows).
# test/test_patch_tool.zsh -- patch/tool.zsh 無論 %PROGRAMFILES% 在哪裡都找得到 Git 的 patch（Windows）。
#
#   ./test/test_patch_tool.zsh          run / 執行
#   ./test/test_patch_tool.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# The candidate read ${ProgramFiles:-C:/Program Files}. The zsh port has only PROGRAMFILES, so the
# lower-case read was always empty and the line always meant C:/Program Files: Git installed on
# D: or per-user was missed (2026-10-30 review, finding G). Here PROGRAMFILES points at a fake tree
# holding Git/usr/bin/patch.exe, in the backslash form Windows sets, and tool.zsh must pick it.
# The control unsets both names and checks the fake is NOT picked, so a test that passed by
# finding any patch would fail there.
# 候選讀的是 ${ProgramFiles:-C:/Program Files}。zsh port 只有 PROGRAMFILES，小寫的讀取永遠是空的，該行
# 永遠代表 C:/Program Files：Git 裝在 D: 或使用者目錄就找不到（2026-10-30 審查，發現 G）。此處讓
# PROGRAMFILES 指向一棵含 Git/usr/bin/patch.exe 的假目錄樹，以 Windows 設定的反斜線形式，tool.zsh 必須選中
# 它。對照組把兩個名稱都清掉，檢查假的那個**不**被選中，使「找到任何 patch 就通過」的測試在那裡失敗。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

case $OSTYPE in
  msys*|mingw*|cygwin*) ;;
  *) printf '%s\n' "SKIP: %PROGRAMFILES% is a Windows variable / %PROGRAMFILES% 是 Windows 的變數" \
                   "PASS: 0  FAIL: 0  SKIP: 1"; exit 0 ;;
esac

ROOT="${script_path:h:h}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# A candidate ahead of PROGRAMFILES in tool.zsh's list would be picked first and hide the line.
# tool.zsh 清單中排在 PROGRAMFILES 之前的候選會先被選中，遮住這一行。
for c in /usr/bin/patch.exe /c/msys64/usr/bin/patch.exe; do
  if [[ -x $c ]]; then
    printf '%s\n' "SKIP: $c exists and is tried first / $c 存在且會先被嘗試" "PASS: 0  FAIL: 0  SKIP: 1"
    exit 0
  fi
done

pass=0 fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }

mkdir -p "$TMP/pf/Git/usr/bin" "$TMP/home"
printf '#!/bin/sh\n' > "$TMP/pf/Git/usr/bin/patch.exe"
chmod +x "$TMP/pf/Git/usr/bin/patch.exe"
fake_w=$(cygpath -w "$TMP/pf")

# pick <env assignments...> -- what swift_tar_patch_tool prints in a child zsh with that env.
# The child's own exit status is not the subject: the control expects whatever real patch is found.
# pick <環境設定...>——在帶有該環境的子 zsh 中，swift_tar_patch_tool 印出的內容。子程序自身的結束碼
# 不是測試對象：對照組預期的是實際找到的任何 patch。
pick() {
  env -u ProgramFiles -u PROGRAMFILES HOME="$TMP/home" "$@" \
    zsh -f -c '. "$1"; swift_tar_patch_tool' _ "$ROOT/patch/tool.zsh" 2>"$TMP/err" </dev/null \
    || true  # the control may legitimately find no patch at all / 對照組可能確實一個 patch 都找不到
}

got=$(pick PROGRAMFILES="$fake_w")
[[ ${got:l} == *pf/git/usr/bin/patch.exe || ${got:l} == *'pf\git\usr\bin\patch.exe' ]] \
  && ok "PROGRAMFILES (upper case, backslashes) is used / 使用 PROGRAMFILES（大寫、反斜線）" \
  || bad "PROGRAMFILES is used: got '$got'"
got=$(pick ProgramFiles="$fake_w")
[[ ${got:l} == *pf/git/usr/bin/patch.exe || ${got:l} == *'pf\git\usr\bin\patch.exe' ]] \
  && ok "ProgramFiles (mixed case) still works / ProgramFiles（混合大小寫）仍可用" \
  || bad "ProgramFiles still works: got '$got'"
got=$(pick)
[[ ${got:l} != *pf* ]] \
  && ok "control: with neither set, the fake tree is not picked / 對照組：兩者皆未設時不選假目錄樹" \
  || bad "control: the fake tree was picked without PROGRAMFILES: '$got'"

printf 'PASS: %d  FAIL: %d  SKIP: 0\n' $pass $fail
(( fail == 0 ))
