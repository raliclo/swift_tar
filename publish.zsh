#!/usr/bin/env zsh
# =====================================================================
#  publish.zsh -- tag, publish, verify, and rewrite the brew and scoop package files
#  publish.zsh -- 打 tag、發布、驗證，並改寫 brew 與 scoop 的套件檔
#
#    ./publish.zsh 0.1.0              say what would happen, change nothing / 只說會做什麼
#    ./publish.zsh 0.1.0 --publish    do it / 真的執行
#    ./publish.zsh --help             print this and do nothing / 印出這段說明
#
#  Put the four archives release.zsh made on each node into dist/ first:
#  macos-arm64, linux-x86_64, linux-aarch64 and windows-x86_64, each with its .sha256.
#  This does not build, test or collect them. It rewrites Formula/swift_tar.rb (the brew
#  tap, macOS arm64) and ../bucket/swift_tar.json (the scoop bucket in the parent lzfse2
#  repository, Windows x86_64); committing those two is left to you.
#  先把各節點 release.zsh 產生的四份封存（macos-arm64、linux-x86_64、linux-aarch64、
#  windows-x86_64，各帶 .sha256）放進 dist/。這支腳本不建置、不測試、不收集。它改寫
#  Formula/swift_tar.rb（brew tap，macOS arm64）與 ../bucket/swift_tar.json（上層 lzfse2 repo
#  的 scoop bucket，Windows x86_64）；兩者的 commit 留給你。
# =====================================================================
# Ported from csv2's publish.zsh (/Volumes/LinuxCS/sos/csv2), which replaced seven hand steps
# after the one mistake in its v0.1.0 lived in them. Its lessons are kept: checksums are
# recomputed here, never copied; each binary must carry this commit's build id; every asset is
# downloaded back from the public URL; the package files are generated, read back, and checked
# for any stale version, while prose that names a version as history is left alone.
# 移植自 csv2 的 publish.zsh：csv2 v0.1.0 唯一的錯誤出在七個手動步驟裡，它就是那七步。它的教訓
# 都保留：校驗和在這裡重算，從不抄寫；每個執行檔都必須帶著這個 commit 的 build id；每個資產都從
# 公開網址下載回來比對；套件檔由程式產生、讀回，並檢查不得殘留舊版本號，而把版本號當歷史記載的
# 散文則不動。

emulate -L zsh
setopt no_unset pipe_fail errexit

TRAPZERR() {
  print -u2 -- "publish.zsh: a command failed and errexit stopped the run; the last line above says how far it got"
  print -u2 -- "publish.zsh：某個命令失敗，errexit 中止了這次執行；上面最後一行說明它走到哪裡"
  print -u2 -- "if the release was already created, its assets and the package files may disagree; check before retrying"
  print -u2 -- "若 release 已經建立，它的資產與套件檔可能不一致；重試前請先確認"
}

HERE=${0:A:h}
cd -- "$HERE"

REPO=raliclo/swift_tar
# --help answers before the version is read, so it is never taken for one.
# --help 在讀取版本之前回答，所以不會被當成版本。
case ${1:-} in
  -h|--help) sed -n '3,18p' ${0:A} | sed 's/^# \{0,2\}//'; exit 0 ;;
  -*) print -ru2 -- "the first argument is the version, not an option (got: $1); see --help / 第一個引數是版本，不是選項（收到：$1），請見 --help"; exit 2 ;;
esac
VERSION=${1:-}
DO_PUBLISH=0
for arg in "${@:2}"; do
  case $arg in
    --publish) DO_PUBLISH=1 ;;
    *) print -ru2 -- "unknown argument: $arg / 不認得的引數：$arg"; exit 2 ;;
  esac
done
[[ $VERSION == <->.<->.<-> ]] || {
  print -u2 -- "usage: ./publish.zsh <X.Y.Z> [--publish]   e.g. ./publish.zsh 0.1.0"
  print -u2 -- "用法：./publish.zsh <X.Y.Z> [--publish]    例如 ./publish.zsh 0.1.0"
  exit 2
}
TAG=v$VERSION
DIST=$HERE/dist
FORMULA=$HERE/Formula/swift_tar.rb
MANIFEST=${SWIFT_TAR_SCOOP_MANIFEST:-$HERE/../bucket/swift_tar.json}
# The platforms a release carries. All four or none: a platform missing from a release leaves
# its package file's url on the old version while its version line moves, and brew or scoop
# then installs the old binary under the new number without an error (csv2, 2026-10-19).
# 一次出貨帶的平台。四個都要有，否則不發：少了一個平台時，它的套件檔 version 會前進、url 卻留在
# 舊版，brew 或 scoop 就會把舊的執行檔標著新版本號裝上，沒有任何錯誤（csv2，2026-10-19）。
PLATFORMS=(macos-arm64 linux-x86_64 linux-aarch64 windows-x86_64)

say() { print -r -- "$1" }
would() { if (( DO_PUBLISH )); then print -r -- "  $1"; else print -r -- "  WOULD  $1"; fi }
die() { print -ru2 -- "$1"; [[ -z ${2:-} ]] || print -ru2 -- "$2"; exit 1 }

# ---------------------------------------------------------------------
# 1. Refuse before touching anything outward-facing.
# 1. 在碰任何對外的東西之前先拒絕。
# ---------------------------------------------------------------------
[[ $VERSION == "$(<VERSION)" ]] || die "VERSION says $(<VERSION), not $VERSION; the binaries carry VERSION's number" \
                                       "VERSION 寫的是 $(<VERSION)，不是 $VERSION；執行檔帶的是 VERSION 的版本號"
# version-<platform>.txt is exempt, as in build_id.zsh: building this node's public archive
# rewrites it, and that rewrite is what the build writes, not a change to what was tagged.
# version-<平台>.txt 豁免，與 build_id.zsh 相同：在這個節點建公開版封存會改寫它，那是建置寫出的
# 東西，不是對 tag 內容的改動。
dirty=$(git status --porcelain --untracked-files=no -- . ':(exclude)version-*.txt')
[[ -z $dirty ]] || {
  print -ru2 -- "$dirty"
  die "the working tree is not clean; the tag would name a state that was not published" \
      "工作區不乾淨；tag 會指向一個沒有被發布的狀態"
}
[[ -r $FORMULA ]] || die "$FORMULA is missing" "缺少 $FORMULA"
[[ -r $MANIFEST ]] || die "$MANIFEST is missing; the scoop bucket lives in the parent lzfse2 repository (or set SWIFT_TAR_SCOOP_MANIFEST)" \
                          "缺少 $MANIFEST；scoop bucket 在上層 lzfse2 repo（或設定 SWIFT_TAR_SCOOP_MANIFEST）"
git fetch -q --tags origin
[[ -z "$(git rev-list @{upstream}..HEAD 2>/dev/null)" ]] || die "HEAD is ahead of origin; push first, or the tag names a commit nobody can fetch" \
                                                               "HEAD 領先 origin；請先推送，否則 tag 指向一個沒人抓得到的 commit"
# What is refused is a published release, not an existing tag: archives must be built AT the
# tag for their build id to say the version, so the order is tag, build, collect, publish.
# 要拒絕的是已發布的 release，不是已存在的 tag：封存必須在 tag 上建置，build id 才說得出版本號，
# 所以順序是打 tag、建置、收集、發布。
command -v gh >/dev/null 2>&1 || die "gh is not on PATH" "PATH 上沒有 gh"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated" "gh 尚未登入"
TAG_EXISTED=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && die "$TAG is already published; re-cutting it disturbs anyone who fetched it, pick the next version" \
                                                          "$TAG 已經發布過；重打會動到抓過它的人，請改用下一個版本號"
  [[ $(git rev-parse "$TAG^{commit}") == $(git rev-parse HEAD) ]] || die "$TAG points at $(git rev-parse --short=8 "$TAG^{commit}"), not HEAD $(git rev-parse --short=8 HEAD)" \
                                                                         "$TAG 指向 $(git rev-parse --short=8 "$TAG^{commit}")，不是 HEAD $(git rev-parse --short=8 HEAD)"
  TAG_EXISTED=1
fi

# ---------------------------------------------------------------------
# 2. The archives: checksums recomputed, the .sha256 from the building node compared, the
#    content listed, and the binary's build id matched against the commit being published.
# 2. 封存：重算校驗和、與建置節點寫的 .sha256 比對、列出內容，並把執行檔的 build id 與正在發布的
#    commit 比對。
# ---------------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r -- "$1" | cut -d' ' -f1; fi
}
HEAD_SHA=$(git rev-parse HEAD)
VERSION_RE=${VERSION//./\\.}

# The binary must carry `v<VERSION> / <8 hex>` for THIS commit. Every other check here is
# equally true of an archive built from the previous commit, because the node that built it
# also wrote its .sha256. The pattern is the build id literal alone, as the --version line is
# assembled at run time and appears nowhere whole.
# 執行檔必須帶著這個 commit 的 `v<VERSION> / <8 碼>`。這裡其他的檢查，對「從上一個 commit 建出的
# 封存」同樣成立，因為建它的節點也寫了它的 .sha256。比對的只是 build id 字面值本身，因為
# --version 那一行是執行時組出來的，檔案裡找不到整行。
ARCHIVE_BUILD_ID=""
archive_commit_ok() {   # archive_commit_ok <archive> <inner path>
  local a=$1 inner=$2 base=${1:t} bx ids sha
  local -a idlist
  bx=$(mktemp -d "${TMPDIR:-/tmp}/swift_tar-bid.XXXXXX")
  zstd -dq -c -- "$a" | ( cd -- "$bx" && tar -xf - "$inner" )
  # `grep -a`, or a binary match is one "Binary file matches" line; `|| true`, or no match
  # kills the script under errexit before the refusal below can speak.
  # `grep -a`，否則二進位比對只得到一行「Binary file matches」；`|| true`，否則找不到時 errexit 會在
  # 下面的拒絕說話之前就殺掉腳本。
  ids=$(LC_ALL=C grep -a -o -E "v$VERSION_RE / [0-9a-f]{8,40}" "$bx/$inner" | LC_ALL=C sort -u || true)
  rm -rf -- "$bx"
  [[ -n $ids ]] || { print -ru2 -- "$base: the binary carries no build id \"v$VERSION / <commit>\"; it was not built at $TAG"
                     print -ru2 -- "$base：執行檔裡沒有「v$VERSION / <commit>」形狀的 build id；它不是在 $TAG 上建的"; return 1 }
  # Into an array: a subscript on the expansion takes the first character, not the first line.
  # 存進陣列：直接對展開式下標拿到的是第一個字元，不是第一行。
  idlist=(${(f)ids})
  (( ${#idlist} == 1 )) || { print -ru2 -- "$base: the binary carries ${#idlist} build ids: ${idlist[*]}"
                             print -ru2 -- "$base：執行檔裡有 ${#idlist} 個 build id：${idlist[*]}"; return 1 }
  sha=${idlist[1]##* / }
  [[ $HEAD_SHA == $sha* ]] || { print -ru2 -- "$base was built from another commit: its binary says ${idlist[1]}, this release is ${HEAD_SHA[1,8]}"
                                print -ru2 -- "$base 是從別的 commit 建的：執行檔說 ${idlist[1]}，這次發布的是 ${HEAD_SHA[1,8]}"; return 1 }
  ARCHIVE_BUILD_ID=${idlist[1]}
}

typeset -a ARCHIVES
typeset -A HASH
for plat in $PLATFORMS; do
  a=$DIST/swift_tar-$VERSION-$plat.tar.zst
  [[ -r $a ]] || die "missing $a; every platform ships or none does (run release.zsh on that node and collect it)" \
                     "缺少 $a；四個平台都要有才發布（在該節點跑 release.zsh 並收集回來）"
  ARCHIVES+=("$a")
done
extra=( "$DIST"/swift_tar-$VERSION-*.tar.zst(N) )
(( ${#extra} == ${#ARCHIVES} )) || die "dist/ holds ${#extra} swift_tar-$VERSION archives, expected exactly ${#ARCHIVES}: ${extra:t}" \
                                       "dist/ 裡有 ${#extra} 份 swift_tar-$VERSION 封存，預期恰好 ${#ARCHIVES} 份：${extra:t}"

say "publish swift_tar $VERSION as $TAG / 將 swift_tar $VERSION 以 $TAG 發布"
say "  commit  : ${HEAD_SHA[1,8]}"
say "  archives:"
for a in $ARCHIVES; do
  base=${a:t}
  h=$(sha256_of "$a")
  HASH[$base]=$h
  [[ -r $a.sha256 ]] || die "$base has no .sha256 beside it; release.zsh writes one, so this archive did not come from it" \
                            "$base 旁邊沒有 .sha256；release.zsh 會寫一個，所以這份封存不是它產生的"
  claimed=$(awk '{print $1}' "$a.sha256")
  [[ $claimed == $h ]] || die "$base: the building node's .sha256 says $claimed, this machine computes $h" \
                              "$base：建置節點的 .sha256 寫 $claimed，這台機器算出 $h"
  stem=${base%.tar.zst}
  inner=$(zstd -dq -c -- "$a" | tar -tf - | grep -E "^$stem/swift_tar(\.exe)?$" | head -1 || true)
  [[ -n $inner ]] || die "$base does not contain $stem/swift_tar or $stem/swift_tar.exe" \
                         "$base 裡沒有 $stem/swift_tar 或 $stem/swift_tar.exe"
  archive_commit_ok "$a" "$inner" || exit 1
  say "    $base  $h  $ARCHIVE_BUILD_ID"
done

# ---------------------------------------------------------------------
# 3. Tag.  4. Release with every archive and .sha256.  5. Download back and compare.
# 3. 打 tag。4. 帶著每份封存與 .sha256 建立 release。5. 下載回來比對。
# ---------------------------------------------------------------------
say ""
say "steps / 步驟："
if (( TAG_EXISTED )); then
  say "  $TAG already points at HEAD and nothing is published from it; reusing it"
  (( DO_PUBLISH )) && git push -q origin "$TAG"
else
  would "git tag -a $TAG && git push origin $TAG"
  if (( DO_PUBLISH )); then
    git tag -a "$TAG" -m "swift_tar $VERSION"
    git push -q origin "$TAG"
  fi
fi

typeset -a ASSETS
for a in $ARCHIVES; do ASSETS+=("$a" "$a.sha256"); done
would "gh release create $TAG -R $REPO with ${#ASSETS} assets"
if (( DO_PUBLISH )); then
  gh release create "$TAG" -R "$REPO" --verify-tag \
    --title "swift_tar $VERSION" \
    --notes "swift_tar $VERSION, the public build (no LZFSE). One .tar.zst per platform, each packed and verified on the machine that built its binary; check it with the .sha256 beside it. macOS: brew; Windows: scoop; Linux: extract and put swift_tar on PATH (needs libbz2.so.1.0)." \
    "${ASSETS[@]}" >/dev/null
fi

would "re-download each asset from the public URL and compare against the local file"
if (( DO_PUBLISH )); then
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
  for a in $ARCHIVES; do
    base=${a:t}
    url=https://github.com/$REPO/releases/download/$TAG/$base
    curl -sfL "$url" -o "$tmp/$base" || die "$base is not downloadable at $url" "$base 在 $url 下載不到"
    got=$(sha256_of "$tmp/$base")
    [[ $got == ${HASH[$base]} ]] || die "$base downloaded as $got, was published as ${HASH[$base]}" \
                                        "$base 下載回來是 $got，發布的是 ${HASH[$base]}"
    say "    verified from the public URL: $base"
  done
fi

# ---------------------------------------------------------------------
# 6. The package files, generated from the archives rather than typed, then read back.
# 6. 套件檔：由封存產生而不是打字，然後讀回。
# ---------------------------------------------------------------------
base_url=https://github.com/$REPO/releases/download/$TAG
# prose_lines, data_text, rewrite_version, rewrite_pair: in their own file so the test can run
# them on copies of the package files.
# prose_lines、data_text、rewrite_version、rewrite_pair 放在獨立的檔案裡，讓測試能拿套件檔的複本跑。
source "$HERE/publish_rewrite.zsh"

typeset -A TARGET_OF=(macos-arm64 $FORMULA windows-x86_64 $MANIFEST)
for plat in ${(k)TARGET_OF}; do
  f=${TARGET_OF[$plat]}
  would "rewrite ${f:t} for swift_tar-$VERSION-$plat.tar.zst"
  if (( DO_PUBLISH )); then
    rewrite_version "$f" "${f:e}"
    rewrite_pair "$f" "swift_tar-$VERSION-$plat.tar.zst" "${HASH[swift_tar-$VERSION-$plat.tar.zst]}"
  fi
done

if (( DO_PUBLISH )); then
  # Read back: a rewrite that silently did nothing looks exactly like one that worked.
  # 讀回：一次靜默什麼都沒做的改寫，看起來與成功的一模一樣。
  for plat in ${(k)TARGET_OF}; do
    f=${TARGET_OF[$plat]}; base=swift_tar-$VERSION-$plat.tar.zst
    grep -qF -- "$base_url/$base" "$f" || die "${f:t} does not name $base_url/$base" "${f:t} 沒有寫 $base_url/$base"
    grep -qF -- "${HASH[$base]}" "$f" || die "${f:t} names $base but not its sha256 ${HASH[$base]}" \
                                             "${f:t} 提到了 $base，卻沒有它的 sha256 ${HASH[$base]}"
    stale=$(data_text "$f" "${f:e}" | LC_ALL=C grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | LC_ALL=C sort -u | LC_ALL=C grep -vxF -- "$VERSION" || true)
    [[ -z $stale ]] || die "${f:t} still carries version(s) other than $VERSION: ${stale//$'\n'/ }" \
                           "${f:t} 裡還留著不是 $VERSION 的版本號：${stale//$'\n'/ }"
    say "    ${f:t}: $base, its sha256 and version $VERSION agree"
  done
fi

say ""
if (( DO_PUBLISH )); then
  say "published: https://github.com/$REPO/releases/tag/$TAG"
  say "next, by hand: commit and push Formula/swift_tar.rb here and bucket/swift_tar.json in the parent repo,"
  say "then upgrade each node and read --version on PATH:"
  say "  macOS    brew update && brew upgrade raliclo/swift_tar/swift_tar"
  say "  Windows  scoop update swift_tar"
  say "接下來由人手做：提交並推送這裡的 Formula/swift_tar.rb 與上層 repo 的 bucket/swift_tar.json，"
  say "然後升級各節點，並讀 PATH 上那一份的 --version。"
else
  say "nothing was changed. Re-run with --publish to do the above."
  say "什麼都沒有改動。加上 --publish 才會真的執行。"
fi
