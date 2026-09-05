#!/usr/bin/env zsh
# =====================================================================
# sync_all.zsh -- report how far each submodule's pin is behind the branch it
#                 tracks, and move the pin only when asked.
# sync_all.zsh -- 回報各 submodule 的 pin 落後其追蹤分支多少，並且只在被要求時才移動。
#
# 預設**只回報**。移動一個 codec 的 pin 會改變 swift_tar 連結的東西，而那件事必須跟著
# 四個平台的重新建置與重新測試，不能是一支腳本順手做掉的。
# Reporting is the default. Moving a codec's pin changes what swift_tar links against, and
# that has to be followed by a rebuild and a test run on four platforms; it is not
# something a script does in passing.
#
# ---------------------------------------------------------------------
# 為什麼分支名一律取自 .gitmodules 的 `branch =`，而不是 origin/HEAD
#
# 這不是風格。zlib 與 zstd 的 pin **就是** `origin/master` 與 `origin/release` 的 tip，
# 但兩者的 `origin/HEAD` 分別指向 `develop` 與 `dev`，於是「落後幾個 commit」量出來是
# 85 與 382。那兩個數字沒有錯——它們量的是另一條分支。依它們去「更新」，會把一個穩定
# 版本的 pin 換成開發線的 tip，而畫面上完全看不出發生了什麼。
#
# 這正是 `.gitmodules` 裡每個 submodule 都寫上 `branch =` 的原因。本腳本讀那一行；讀不到
# 就拒絕處理該 submodule，而不是退回 origin/HEAD——退回去等於把陷阱重新裝好。
#
# The branch comes from `.gitmodules`, never from origin/HEAD. The zlib and zstd pins *are*
# the tips of origin/master and origin/release, yet their origin/HEAD point at develop and
# dev, so "commits behind" measured 85 and 382. Those numbers were right about a different
# branch, and updating on them would have swapped a stable pin for a development tip with
# nothing on screen to show it. A submodule with no `branch =` is refused rather than
# falling back, because falling back is what re-arms the trap.
# ---------------------------------------------------------------------
#
# 用法 / Usage:
#   ./sync_all.zsh                     回報全部，不改任何東西 / report only
#   ./sync_all.zsh --update NAME...    把指名的 submodule 的 pin 移到分支 tip
#   ./sync_all.zsh --update --all      移動所有**外部**依賴的 pin（不含 lzfse2）
#   ./sync_all.zsh --no-fetch          不 fetch，用本地已有的 remote ref 回報
#   ./sync_all.zsh --help
#
# `--update` 只改工作區與 gitlink，**不提交、不推送**。改完要做什麼，腳本會列出來。
# `--update` stages nothing and commits nothing; it prints what must follow.
# =====================================================================
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '3,40p' "${0:A}" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT=${0:A:h}
cd "$ROOT"

# lzfse2 是私有引擎，不是「外部依賴」。它的 pin 由這棵樹自己決定，且與 swift_tar 的
# commit 成對前進，故 --all 不會碰它。要動它必須指名，而那時你應該已經知道自己在做什麼。
# lzfse2 is the private engine, not an external dependency: its pin is this tree's own and
# moves in step with swift_tar's commits, so --all leaves it alone. Naming it explicitly
# still works, for whoever already knows why they want that.
PRIVATE=(lzfse2)

UPDATE=0
ALL=0
FETCH=1
typeset -a WANT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)   UPDATE=1; shift ;;
    --all)      ALL=1; shift ;;
    --no-fetch) FETCH=0; shift ;;
    -*) print -ru2 -- "unknown option: $1"; exit 2 ;;
    *)  WANT+=("$1"); shift ;;
  esac
done
(( UPDATE )) && (( ! ALL )) && (( ${#WANT} == 0 )) && {
  print -ru2 -- "--update needs submodule names, or --all / --update 需要指名，或用 --all"
  exit 2
}

typeset -a NAMES
NAMES=(${(f)"$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')"})

print -- "submodule pins vs the branch each one tracks / 各 submodule 的 pin 對其追蹤分支"
print -- "  repo: $ROOT"
(( FETCH )) && print -- "  fetching remotes… / 正在 fetch…"
print --

typeset -a MOVED STALE
for m in $NAMES; do
  br=$(git config -f .gitmodules --get "submodule.$m.branch" 2>/dev/null || true)
  private=""; [[ ${PRIVATE[(Ie)$m]} -ne 0 ]] && private=" [private]"

  if [[ -z $br ]]; then
    # 讀不到就拒絕，不退回 origin/HEAD——見檔頭。
    print -- "  ✗ $m$private — .gitmodules 沒有 branch=，拒絕處理 / no branch= recorded, refusing"
    STALE+=("$m")
    continue
  fi
  if [[ ! -e $m/.git ]]; then
    print -- "  – $m$private — 未 checkout / not checked out (branch=$br)"
    continue
  fi

  # 有本地修改就完全不碰。一個把別人未提交的工作蓋掉的同步腳本，比不同步糟得多。
  # Never touch a submodule with local changes: a sync script that discards someone's
  # uncommitted work is worse than one that does nothing.
  dirty=""
  [[ -n $(git -C $m status --porcelain 2>/dev/null) ]] && dirty=" (有本地修改／dirty)"

  (( FETCH )) && git -C $m fetch --quiet origin 2>/dev/null || true

  pin=$(git -C $m rev-parse --short HEAD 2>/dev/null || print -r -- "?")
  desc=$(git -C $m describe --tags HEAD 2>/dev/null | head -1 || true)
  if ! tip=$(git -C $m rev-parse --short "origin/$br" 2>/dev/null); then
    print -- "  ✗ $m$private — 取不到 origin/$br / cannot resolve origin/$br"
    STALE+=("$m")
    continue
  fi
  behind=$(git -C $m rev-list --count "HEAD..origin/$br" 2>/dev/null || print -r -- "?")

  # pin 在不在那條分支上，與「落後幾個」是兩個問題。pin 若不在分支上，落後數就沒有意義。
  # Whether the pin is on that branch is a separate question from how far behind it is; if
  # it is not on the branch, the behind-count means nothing.
  if git -C $m merge-base --is-ancestor HEAD "origin/$br" 2>/dev/null; then
    onbranch="on $br"
  else
    onbranch="NOT on $br — 落後數無意義 / behind-count is meaningless"
  fi

  if [[ $behind == 0 ]]; then
    print -- "  ✓ $m$private — 已是 origin/$br 的 tip / at tip  ($pin${desc:+ $desc})$dirty"
    continue
  fi

  print -- "  ↑ $m$private — 落後 $behind / behind  ($pin${desc:+ $desc} → $tip, $onbranch)$dirty"

  wanted=0
  (( ALL )) && [[ ${PRIVATE[(Ie)$m]} -eq 0 ]] && wanted=1
  [[ ${WANT[(Ie)$m]} -ne 0 ]] && wanted=1
  (( UPDATE )) && (( wanted )) || continue

  if [[ -n $dirty ]]; then
    print -- "      跳過：有本地修改 / skipped: local changes"
    continue
  fi
  git -C $m checkout --quiet --detach "origin/$br"
  newpin=$(git -C $m rev-parse --short HEAD)
  print -- "      → 已移到 $newpin（工作區，尚未提交）/ moved to $newpin (working tree, not committed)"
  MOVED+=("$m $pin → $newpin")
done

print --
if (( ${#STALE} )); then
  print -- "無法處理 / could not handle: ${STALE[*]}"
fi

if (( ${#MOVED} == 0 )); then
  (( UPDATE )) && print -- "沒有任何 pin 被移動 / no pin was moved" \
                || print -- "只回報，未改動任何東西。加 --update 才會移動 / report only; --update moves pins"
  exit 0
fi

# 移動了 pin 就一定要跟著這些步驟。把它們印出來，而不是假設下一個人記得——這棵樹已經
# 因為「改了卻沒在每個平台跑過」付過代價（--exclude 在 macOS 驗得很細，Windows 七天
# 建不起來）。
# A moved pin has to be followed by these. They are printed rather than assumed, because
# this tree has already paid for a change verified on one platform only.
print -- "已移動 / moved:"
for l in $MOVED; do print -- "  $l"; done
print --
print -- "接下來必須做的事（腳本不會替你做）/ what must follow, none of it automatic:"
print -- "  1. 四個平台各自重建：./build.zsh（mac/win）、./compile_tar-linux.zsh（linux/WSL）"
print -- "     Rebuild on all four platforms."
print -- "  2. 各平台跑測試：test/ 底下的套件，以及 verifications/tar_interop_matrix.zsh"
print -- "     Run the suites and the interop matrix on each."
print -- "  3. version-<平台>.txt 會由建置更新，確認其中的 codec 版本確實變了"
print -- "     Confirm the codec versions in version-<plat>.txt actually moved."
print -- "  4. verifications/record_release.zsh --record 於各平台重記 sha256"
print -- "     Re-record each binary's sha256."
print -- "  5. 效能可能改變：verifications/profile/extract_shapes.zsh --record"
print -- "     Performance may move; re-measure."
print -- "  6. 最後才提交 gitlink，且訊息要寫明升級了什麼、在哪些平台驗過"
print -- "     Commit the gitlink last, saying what moved and where it was verified."
