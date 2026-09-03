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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) RECORD=1; shift ;;
    --binary) BINARY="${2:?--binary needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $1" >&2; exit 2 ;;
  esac
done

# 預設找建置產物；Windows 上帶 .exe。不猜，看哪一個真的存在。
# Default to the build output; .exe on Windows. Do not guess -- see which one exists.
if [[ -z $BINARY ]]; then
  for candidate in "$ROOT/release/swift_tar" "$ROOT/release/swift_tar.exe"; do
    [[ -f $candidate ]] && { BINARY=$candidate; break }
  done
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

BYTES=$(zstat +size "$BINARY" 2>/dev/null || stat -f %z "$BINARY")

VERSION_FILE="$ROOT/version-$PLAT.txt"
STAMP=$(sed -n 's/^swift_tar_version=//p' "$VERSION_FILE" 2>/dev/null | sed -n '1p')
[[ -n $STAMP ]] || STAMP="(none)"

# 工作區是否乾淨很重要：由有未提交變更的樹建出的執行檔，那個 commit 並不能識別它。
# Whether the worktree was clean matters: a binary built from a dirty tree is not
# identified by that commit.
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
