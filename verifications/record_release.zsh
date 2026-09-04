#!/usr/bin/env zsh
# =====================================================================
# record_release.zsh -- record one built binary's sha256 in release_matrix.csv2.
# record_release.zsh -- 把一個已建置執行檔的 sha256 記入 release_matrix.csv2。
#
# 這個檔案的存在理由，是 `generate_version.zsh` 讓出的那個性質。自 d868dc3 起，
# swift_tar_version 的語意是「來源資訊何時改變」，不再是「這個執行檔何時被編譯」——
# 那次變更的理由明白寫著：辨識執行檔本來就不該靠時間戳，release_matrix 記的 sha256
# 才是答案。當時那個檔案並不存在，於是被讓出的性質有一個明載的替代品，而替代品不在。
# 本腳本與 release_matrix.csv2 補上它。
#
# The property `generate_version.zsh` gave up is why this exists. Since d868dc3,
# swift_tar_version means "when the provenance last changed", not "when this binary
# was compiled", and the stated reason was that identity was never a timestamp's job
# -- the release matrix's sha256 is the answer. No such file existed, so the property
# had a documented replacement that was not there. This supplies it.
#
# 追加式，不覆寫。同一個平台、同一個版本戳、不同的 sha256 是**正常情況**，而且正是這個
# 檔案要能顯示的事：戳記不再區分兩個執行檔，sha256 才會。若這裡改成「每個平台一列」，
# 就會把唯一有資訊量的那個對照抹掉。
#
# Append-only, never overwrite. Same platform, same stamp, different sha256 is the
# normal case and precisely what this file must be able to show -- the stamp no longer
# separates two binaries and the sha256 does. One row per platform would erase the one
# comparison that carries information.
#
# 用法 / Usage:
#   verifications/record_release.zsh              # 印出將寫入的一列，不寫檔
#   verifications/record_release.zsh --record     # 追加到 release_matrix.csv2
#   verifications/record_release.zsh --binary PATH [--record]
#   verifications/record_release.zsh --verify     # 檢查各列的 git_commit 是否仍取得到
#
# --verify 在有任何一格失效時以非 0 結束，適合放進 CI 或提交前的檢查。它不修改任何檔案，
# 也不自動修——哪個新 hash 對應哪一列，只有建出該執行檔的機器知道。
# --verify exits non-zero if any commit cell has become unreachable. It changes nothing and
# repairs nothing: only the machine that built a binary knows which hash replaced its own.
#
# 不加 --record 就不動已入版的檔案，與本目錄其他腳本一致。
# Without --record it touches no committed file, as the other scripts here do.
# =====================================================================
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h}
MATRIX="$HERE/release_matrix.csv2"

. "$ROOT/platform.zsh"
PLAT=$(swift_tar_platform)

BINARY=""
RECORD=0
VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) RECORD=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --binary) BINARY="${2:?--binary needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $1" >&2; exit 2 ;;
  esac
done

# --verify：檢查每一列的 git_commit 在這個 clone 裡是否還取得到。
#
# 本檔下方已經寫明「git_commit 會被 rebase 改掉」，那段話是 2026-09-04 第一列壞掉之後補的。
# **幾小時後同一件事又發生在 win 兩列上**（`27dc8c9` 與 `06b7dfd`，兩者在此 repo 中皆無此
# 物件），因為記錄發生在 push 之前，而那些本地 commit 在 push 前被改寫了。
#
# 也就是說：把限制寫進註解，擋不住它再發生一次。**要擋就得有人去比對**，而沒有人會為了
# 一個「已知的限制」定期手動比對四列 hash。這個模式讓那件事變成一道指令。
#
# 它不自動修。哪一個新 hash 對應哪一列，只有建出該執行檔的那台機器知道；由此處猜測填入，
# 等於用一個看起來對的值蓋掉一個看得出錯的值。
#
# The note below about rebase rewriting git_commit was added after the first row broke on
# 2026-09-04. Hours later the same thing happened to both win rows, because recording happens
# before pushing and those local commits were rewritten first. A limitation written in a
# comment does not stop it recurring; something has to compare. This mode is that comparison.
# It deliberately does not repair: only the machine that produced a binary knows which new
# hash replaces its old one, and guessing here would overwrite a visibly wrong value with a
# plausible one.
if [[ $VERIFY -eq 1 ]]; then
  [[ -f $MATRIX ]] || { print -r -- "no matrix at $MATRIX" >&2; exit 1 }
  n=$(csv2 -r -i "$MATRIX" | wc -l | tr -d ' ')
  (( n > 0 )) || { print -r -- "matrix has no rows / 表中沒有任何一列" >&2; exit 1 }
  bad=0
  for r in {1..$n}; do
    plat=$(csv2 -get $r:1 -i "$MATRIX")
    commit=$(csv2 -get $r:5 -i "$MATRIX")
    sha=$(csv2 -get $r:3 -i "$MATRIX")
    # 只有「長得像 commit」的值才要求可達。`(not-a-checkout)` 之類帶括號的明確標記是誠實的
    # 值——guest 內建置時那裡沒有 .git，身分本來就由 sha256 承擔——把它報成失敗，等於讓這道
    # 檢查對一個正確的做法亮紅燈。一個會對正確做法報警的檢查，很快就會被當成雜訊而略過，
    # 那時它對真正的失效也一起失效了。
    # Only values that claim to be commits are required to resolve. A parenthesised marker
    # such as `(not-a-checkout)` is an honest value — a guest build has no .git and identity
    # rests on the sha256 — and flagging it would make this check cry wolf. A check that
    # warns about correct practice gets ignored, and then it no longer catches the real thing.
    #
    # `(#c7,40)` needs EXTENDED_GLOB, and it must not be combined with `##`. Written as
    # `[0-9a-f]##(#c7,40)` without the option set, the whole thing is matched literally, so
    # **every** value looks like a non-commit and the check skips every row while exiting 0.
    # Measured: `ef97509`, `9f47258638bf` and `(not-a-checkout)` all took the skip branch;
    # with `setopt extended_glob` and the count alone, the first two are commits and the
    # third is not. A guard written to stop this check crying wolf had turned it into a
    # check that cannot fail, which is worse -- crying wolf is at least visible.
    # `(#c7,40)` 需要 EXTENDED_GLOB，且不可與 `##` 併用。未設定該選項時，
    # `[0-9a-f]##(#c7,40)` 整串會被當成字面比對，於是**每一個**值都像非 commit——檢查跳過
    # 每一列並以 0 結束。實測：`ef97509`、`9f47258638bf` 與 `(not-a-checkout)` 全部走了略過
    # 分支；改為 `setopt extended_glob` 並只用計數之後，前兩者是 commit、第三者不是。
    # 一道為了避免誤報而寫的守門，變成了一道不可能失敗的檢查，那比誤報更糟——誤報至少看得見。
    setopt local_options extended_glob
    if [[ $commit != [0-9a-f](#c7,40) ]]; then
      print -r -- "  – 第 $r 列 ($plat) $commit  非 commit 的明確標記，不適用 / explicit non-commit marker"
      continue
    fi
    if git -C "$ROOT" merge-base --is-ancestor "$commit" HEAD 2>/dev/null; then
      print -r -- "  ✓ 第 $r 列 ($plat) $commit  在 HEAD 的歷史中 / reachable"
    elif git -C "$ROOT" cat-file -e "$commit" 2>/dev/null; then
      print -r -- "  ~ 第 $r 列 ($plat) $commit  存在但不在 HEAD 歷史中 / exists, not in HEAD's history"
      bad=1
    else
      print -r -- "  ✗ 第 $r 列 ($plat) $commit  此 clone 中不存在 / no such object here"
      print -r -- "      sha256 仍然有效，身分未失 / the sha256 still identifies it: ${sha:0:16}…"
      bad=1
    fi
  done
  if (( bad )); then
    print -r -- ""
    print -r -- "git_commit 是脈絡，不是身分——失效的格子不影響 sha256。"
    print -r -- "修法：由建出該執行檔的機器提供新 hash，csv2 -update r:5 <新hash>。不要猜。"
    print -r -- "The commit column is context, not identity. Repair from the machine that built it."
  fi
  exit $bad
fi

# 依 $PLAT 決定要哪一個產物，不是「哪個先找到算哪個」。原本的順序在兩者皆存在時會挑錯：
# 這台 Windows 機器以 WSL 建 Linux 版，兩邊的產物都落在同一個 release/（WSL 共用
# /mnt/c），於是 2026-09-04 在 Windows 上挑到了 release/swift_tar——那是 Linux ELF，
# 而該列會以 platform=win 記下它的 sha256。誤標身分正是這張表要防的事，所以本平台的產物
# 不在時直接報錯，不退而求其次：退回另一個檔只會把錯誤寫得更像真的。
# Choose by $PLAT rather than first-one-found. The old order picks the wrong file whenever
# both exist: this Windows box builds the Linux binary under WSL and both land in the same
# release/ (WSL shares /mnt/c), so on 2026-09-04 it picked release/swift_tar -- a Linux ELF
# whose sha256 would have been recorded as platform=win. Misattributed identity is the exact
# thing this table exists to prevent, so a missing binary for this platform is an error
# rather than a fallback: falling back to the other file only makes the wrong row look real.
if [[ -z $BINARY ]]; then
  case $PLAT in
    win) want="$ROOT/release/swift_tar.exe" ;;
    *)   want="$ROOT/release/swift_tar" ;;
  esac
  [[ -f $want ]] && BINARY=$want
fi
[[ -n $BINARY && -f $BINARY ]] || {
  print -r -- "no binary found; build first, or pass --binary PATH" >&2
  print -r -- "找不到執行檔；請先建置，或以 --binary PATH 指定" >&2
  exit 1
}

# sha256 的工具依平台而異。以「跑得動」挑選，不以名稱挑選——本樹已因後者踩過坑。
# The sha256 tool differs by platform. Pick the one that runs, not the one with the
# expected name; this tree has been bitten by choosing on the name.
SHA=""
if print -n "" | shasum -a 256 >/dev/null 2>&1; then
  SHA=$(shasum -a 256 "$BINARY" | cut -d' ' -f1)
elif print -n "" | sha256sum >/dev/null 2>&1; then
  SHA=$(sha256sum "$BINARY" | cut -d' ' -f1)
else
  print -r -- "no working sha256 tool (tried shasum -a 256, sha256sum)" >&2
  exit 1
fi

# `zstat` 需要顯式 zmodload：它是否已定義取決於 module_path，macOS 上會自動載入，而
# Windows 的 zsh port 不會——於是 2026-09-04 在 Windows 上掉到 BSD 的 `stat -f %z`，
# 而 GNU／MSYS 的 stat 把 `-f` 讀成「顯示檔案系統資訊」，回報
# `cannot read file system information for '%z'`，整支腳本停在這裡。三段備援依序涵蓋
# zsh 模組、GNU 與 BSD，與本檔挑 sha256 工具時「以跑得動挑選」的作法一致。
# `zstat` needs an explicit zmodload: whether it is defined depends on module_path. macOS
# autoloads it and the Windows zsh port does not, so on 2026-09-04 this fell through to BSD
# `stat -f %z`, and GNU/MSYS stat reads `-f` as "show filesystem status" -- it answered
# `cannot read file system information for '%z'` and the script stopped here. The three-way
# fallback covers the zsh module, GNU and BSD, the same "pick what runs" rule this file
# already applies to the sha256 tool.
zmodload zsh/stat 2>/dev/null
BYTES=$(zstat +size "$BINARY" 2>/dev/null \
        || stat -c %s "$BINARY" 2>/dev/null \
        || stat -f %z "$BINARY")

VERSION_FILE="$ROOT/version-$PLAT.txt"
STAMP=$(sed -n 's/^swift_tar_version=//p' "$VERSION_FILE" 2>/dev/null | sed -n '1p')
[[ -n $STAMP ]] || STAMP="(none)"

# 工作區是否乾淨很重要：由有未提交變更的樹建出的執行檔，那個 commit 並不能識別它。
#
# 兩點限制要說明白，否則這兩欄會被讀成它們答不了的問題：
#
# 其一，`worktree` 記的是**記錄當下**的狀態，不是建置當下的。兩者只有在「建完立刻記錄」
# 時才是同一件事——這也是預期用法。若在建置與記錄之間改了任何檔案（哪怕改的是本檔），
# 這一欄就會是 dirty，而它描述的其實是記錄那一刻。
#
# 其二，`git_commit` 會被 rebase 改掉，sha256 不會。2026-09-04 就發生了：第一列記下
# `f39e78d`，數分鐘後一次 `pull --rebase` 把同一份內容改寫為 `ef97509`，那一欄於是指向
# 一個任何人都取不到的 commit。**一張以 sha256 記錄身分的表，它的 commit 欄指向不存在的
# commit**——這正是本表要解決的問題換了個形狀。故此欄是脈絡，不是身分；身分永遠是 sha256。
# 若在 rebase 之後才發現某列已失效，修那一格（`csv2 -update r:5 <新hash>`），不要改 sha256。
#
# Whether the worktree was clean matters: a binary built from a dirty tree is not
# identified by that commit. Two limits, stated so these columns are not read as
# answering questions they cannot. First, `worktree` describes the tree at *record*
# time, not at build time; the two coincide only when you record straight after
# building, which is the intended use. Second, `git_commit` is rewritten by a rebase
# and the sha256 is not -- which happened on 2026-09-04, minutes after the first row
# was written. The commit column is context; identity is always the sha256. Fix a
# stale cell with `csv2 -update r:5 <new-hash>`; never touch the sha256.
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || print -r -- "(not-a-checkout)")
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  if [[ -n $(git -C "$ROOT" status --porcelain --untracked-files=no) ]]; then
    TREE="dirty"
  else
    TREE="clean"
  fi
else
  TREE="(unknown)"
fi

WHEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ROW="$PLAT,$STAMP,$SHA,$BYTES,$COMMIT,$TREE,$WHEN"

if [[ $RECORD -eq 0 ]]; then
  print -r -- "would append / 將追加："
  print -r -- "  $ROW"
  print -r -- "pass --record to write / 加上 --record 才會寫入 $MATRIX"
  exit 0
fi

if [[ ! -f $MATRIX ]]; then
  {
    print -r -- "platform,swift_tar_version,sha256,bytes,git_commit,worktree,recorded_utc"
    print -r -- "平台,版本戳,sha256,位元組,git commit,工作區,記錄時間UTC"
  } > "$MATRIX"
fi

csv2 -append "$ROW" -i "$MATRIX" --in-place
print -r -- "recorded / 已記錄： $ROW"
