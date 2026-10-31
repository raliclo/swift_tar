#!/usr/bin/env zsh
# test/test_doc_consistency.zsh -- documents that state a fact the code or the other language also states agree.
# test/test_doc_consistency.zsh -- 文件中與程式或另一語言版本重複陳述的事實保持一致。
#
#   ./test/test_doc_consistency.zsh          run / 執行
#   ./test/test_doc_consistency.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# Two drifts found by the 2026-10-30 review, each silent until someone acted on the wrong copy:
#  - README.zh-TW.md's "extraction stays inside -C" table lacked the row for links already on disk
#    (junctions), which README.md has (finding C). The two tables must have the same number of rows.
#  - verifications/zstd_bmi2_win.zsh's synopsis said ../../claw-code while the code defaults to
#    ../claw-code, so the documented command stopped with "corpus not found" (finding F). Every
#    claw-code path in its synopsis must resolve, from the swift_tar root, to the code's default.
# 2026-10-30 審查發現的兩處漂移，都要等有人照錯的那份去做才會現形：
#  - README.zh-TW.md 的「解出不離開 -C」表少了「磁碟上既有連結（junction）」那一列，README.md 有（發現 C）。
#    兩張表的列數必須相同。
#  - verifications/zstd_bmi2_win.zsh 的用法寫 ../../claw-code，程式預設卻是 ../claw-code，照文件執行會以
#    「corpus not found」中止（發現 F）。用法中每個 claw-code 路徑，自 swift_tar 根目錄解析後都必須等於
#    程式的預設。
set -euo pipefail

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,6p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT="${script_path:h:h}"
pass=0 fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)) }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)) }

# rows <file> <header line> -- the number of table rows under that exact header, separator excluded.
# rows <檔案> <表頭行>——該表頭下的表格列數，不含分隔列。
rows() {
  local file=$1 header=$2 line in=0 n=0
  while IFS= read -r line; do
    if (( in )); then
      [[ $line == '|'* ]] || break
      [[ $line == '|---'* ]] || n=$((n + 1))
    elif [[ $line == "$header" ]]; then
      in=1
    fi
  done < $file
  (( in )) || { printf 'header not found in %s: %s\n' "${file:t}" "$header" >&2; n=-1 }
  printf '%d\n' $n
}

en=$(rows $ROOT/README.md '| member name in the archive | what happens |')
zh=$(rows $ROOT/README.zh-TW.md '| 封存中的成員名稱 | 處理方式 |')
(( en > 0 && en == zh )) \
  && ok "extraction-safety table: $en rows in both READMEs / 兩份 README 皆 $en 列" \
  || bad "extraction-safety table: README.md $en rows, README.zh-TW.md $zh rows"

script=$ROOT/verifications/zstd_bmi2_win.zsh
grep -q -F 'CORPUS=${1:-${REPO:h}/claw-code}' $script \
  && ok "zstd_bmi2_win.zsh: the default is still \${REPO:h}/claw-code / 預設仍為 \${REPO:h}/claw-code" \
  || bad "zstd_bmi2_win.zsh: the CORPUS default changed; update this test and the synopsis"
want=${ROOT:h}/claw-code
paths=( ${(f)"$(sed -n '2,8p' $script | grep -o -E '[./]*claw-code')"} )
(( ${#paths} > 0 )) || bad "zstd_bmi2_win.zsh: no claw-code path in the synopsis"
for p in $paths; do
  [[ ${${:-$ROOT/$p}:a} == $want ]] \
    && ok "zstd_bmi2_win.zsh synopsis: $p is the default / 用法中的 $p 即預設" \
    || bad "zstd_bmi2_win.zsh synopsis: $p resolves to ${${:-$ROOT/$p}:a}, the default is $want"
done

printf 'PASS: %d  FAIL: %d  SKIP: 0\n' $pass $fail
(( fail == 0 ))
