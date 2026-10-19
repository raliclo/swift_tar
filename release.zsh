#!/usr/bin/env zsh
# =====================================================================
#  release.zsh -- package THIS platform's public swift_tar build as one .tar.zst
#  release.zsh -- 把這個平台的公開版 swift_tar 打包成一份 .tar.zst
#
#    ./release.zsh           package release/swift_tar[.exe] into dist/ / 打包進 dist/
#    ./release.zsh --help    print this and do nothing / 印出這段說明，什麼都不做
#
#  Run it on each node, after building the public build there (no LZFSE):
#  macOS ./compile_tar.zsh --no-lzfse, Linux EXCLUDE_LZFSE=1 ./compile_tar-linux.zsh,
#  Windows EXCLUDE_LZFSE=1 zsh ./compile_tar-win.zsh. An archive is made only where its
#  binary was built, so the version inside it can be checked by running it. Collecting the
#  archives and publishing them is publish.zsh's job, not this one's.
#  在每個節點上、先建好公開版（不含 LZFSE）之後各跑一次：macOS ./compile_tar.zsh --no-lzfse、
#  Linux EXCLUDE_LZFSE=1 ./compile_tar-linux.zsh、Windows EXCLUDE_LZFSE=1 zsh ./compile_tar-win.zsh。
#  封存只在建出其執行檔的地方產生，這樣裡面的版本才能靠執行它來檢查。收集與發布是 publish.zsh 的事。
# =====================================================================
# Modelled on csv2's release.zsh (/Volumes/LinuxCS/sos/csv2), including the refusals it learned
# the hard way: the version comes from the binary, never from a constant here; the build id is
# compared anchored, not by containment; an existing archive is never overwritten; and the
# archive is verified by extracting and running it, not by its existence.
# 以 csv2 的 release.zsh 為範本，連同它付過代價才學到的拒絕：版本取自執行檔，不取自這裡的常數；
# build id 以錨定比對，不以包含比對；既有的封存絕不覆寫；封存以解開並執行來驗證，不以存在來驗證。

emulate -L zsh
setopt no_unset pipe_fail errexit

case ${1:-} in
  '') ;;
  -h|--help) sed -n '3,16p' ${0:A} | sed 's/^# \{0,2\}//'; exit 0 ;;
  *) print -ru2 -- "release.zsh takes no argument (got: $1); see --help / release.zsh 不收引數（收到：$1），請見 --help"; exit 2 ;;
esac

# No line number: $LINENO inside a trap function is the function's own line.
# 不報行號：trap 函式裡的 $LINENO 是函式自己的行號。
TRAPZERR() {
  print -u2 -- "release.zsh: a command failed; nothing in dist/ from this run should be trusted"
  print -u2 -- "release.zsh：某個命令失敗；這次執行在 dist/ 留下的東西一律不可信"
  [[ -z ${PACKED:-} ]] || rm -f -- "$PACKED" "$PACKED.sha256"
}

HERE=${0:A:h}
cd -- "$HERE"
DIST=$HERE/dist
# A refusal after packing removes what this run packed: an archive that failed its checks,
# left in dist/ under the release's own name, is one collection away from being published.
# Only this run's file: it was checked not to exist before packing.
# 打包之後的拒絕會刪掉這次打出的東西：一份沒通過檢查、卻以正式名稱留在 dist/ 的封存，離被發布只差
# 一次收集。只刪這次的檔案：打包前已確認它原本不存在。
PACKED=""
die() {
  print -ru2 -- "$1"; [[ -z ${2:-} ]] || print -ru2 -- "$2"
  [[ -z $PACKED ]] || rm -f -- "$PACKED" "$PACKED.sha256"
  exit 1
}

if [[ -x release/swift_tar.exe ]]; then BIN_NAME=swift_tar.exe
elif [[ -x release/swift_tar ]]; then BIN_NAME=swift_tar
else die "no built binary in release/; build the public build first (see --help)" \
         "release/ 裡沒有已建置的執行檔；請先建公開版（見 --help）"; fi
BIN=$HERE/release/$BIN_NAME

case "$(uname -s)" in
  Darwin)                        OS=macos;   PLAT=mac ;;
  Linux)                         OS=linux;   PLAT=linux ;;
  MSYS*|MINGW*|CYGWIN*|Windows*) OS=windows; PLAT=win ;;
  *) die "unknown platform $(uname -s)" "不認得的平台 $(uname -s)" ;;
esac
ARCH=$(uname -m)
VERSION_FILE=$HERE/version-$PLAT.txt
[[ -r $VERSION_FILE ]] || die "$VERSION_FILE is missing; the build writes it" "缺少 $VERSION_FILE；建置會寫出它"

# ---------------------------------------------------------------------
# What the binary says it is, asked by running it.
# 執行檔說它是什麼——靠執行它問出來。
# ---------------------------------------------------------------------
# `swift_tar <X.Y.Z> (<build id>) <stamp>`; a native Windows program is asked from inside
# release/ with a bare name, as it cannot open an MSYS-style absolute path.
# `swift_tar <X.Y.Z> (<build id>) <戳記>`；原生 Windows 程式從 release/ 裡以裸檔名問，因為它開不了
# MSYS 形式的絕對路徑。
REPORTED=$(cd release && "./$BIN_NAME" --version | tr -d '\r')
VERSION=${${(z)REPORTED}[2]}
[[ $VERSION == <->.<->.<-> ]] || die "cannot read a version out of [$REPORTED]; refusing to name an archive by guessing" \
                                     "從 [$REPORTED] 讀不出版本號；拒絕用猜的為封存命名"
[[ $VERSION == "$(<VERSION)" ]] || die "the binary reports $VERSION but VERSION says $(<VERSION); rebuild" \
                                       "執行檔回報 $VERSION，VERSION 卻寫 $(<VERSION)；請重新建置"

# The tree must be clean apart from the version files the build rewrites, or the archive's id
# names a state other than what was packaged. Same exemption as build_id.zsh.
# 除了建置會改寫的 version 檔之外，工作區必須乾淨，否則封存上的 id 指的是別的狀態。與 build_id.zsh
# 的豁免相同。
if [[ -e $HERE/.git ]]; then
  dirty=$(git status --porcelain --untracked-files=no -- . ':(exclude)version-*.txt')
  [[ -z $dirty ]] || { print -ru2 -- "$dirty"; die "the working tree is not clean; an archive built from it would carry an id that describes something else" \
                                                   "工作區不乾淨；由它產生的封存會帶著一個描述別的東西的 id"; }
fi

# The id the binary carries must be the one this checkout gives now. Anchored on `(<id>)`:
# containment would let `v0.1.0-13-g...` pass as `v0.1.0`.
# 執行檔帶的 id 必須等於這個 checkout 現在給的 id。以 `(<id>)` 錨定：用包含比對會讓 `v0.1.0-13-g...`
# 被當成 `v0.1.0`。
source "$HERE/build_id.zsh"
EXPECTED_ID=$(swift_tar_build_id "$HERE")
[[ $EXPECTED_ID != unknown ]] || die "no build id: not a git checkout and SWIFT_TAR_BUILD_ID is not set" \
                                     "沒有 build id：這不是 git checkout，也沒有設定 SWIFT_TAR_BUILD_ID"
[[ $EXPECTED_ID != *-dirty ]] || die "the build id is $EXPECTED_ID; a release is built from a clean tree" \
                                     "build id 是 $EXPECTED_ID；正式版要從乾淨的工作區建置"
[[ $REPORTED == "swift_tar $VERSION ($EXPECTED_ID) "* ]] || die "the binary reports [$REPORTED] but this checkout is ($EXPECTED_ID); rebuild before releasing" \
                                                                "執行檔回報 [$REPORTED]，這個 checkout 卻是（$EXPECTED_ID）；發行前請重新建置"

# The public build only. The version file says what the build compiled in; the binary is then
# asked, and searched, because a version file is something a build writes, not the binary.
# 只發公開版。version 檔說建置編進了什麼；接著再問執行檔、再搜執行檔，因為 version 檔是建置寫出的
# 東西，不是執行檔本身。
grep -qx 'lzfse2=excluded' "$VERSION_FILE" || die "$VERSION_FILE does not say lzfse2=excluded; this is the full build, and only the public one is released" \
                                                  "$VERSION_FILE 沒有寫 lzfse2=excluded；這是完整版，正式版只發公開版"
# `grep -a`: on a binary without it grep prints one "Binary file matches" line, which a count
# reads as one. `|| true`: a count of zero exits 1.
# `grep -a`：少了它，grep 對二進位檔只印一行「Binary file matches」，計數會讀成 1。`|| true`：計數為零
# 時 grep 以 1 結束。
lz_hits=$(LC_ALL=C grep -a -c -E 'bvx3|other3' "$BIN" || true)
[[ $lz_hits == 0 ]] || die "the binary still contains bvx3/other3 strings ($lz_hits lines); not the public build" \
                           "執行檔仍含有 bvx3／other3 字串（$lz_hits 行）；不是公開版"

command -v zstd >/dev/null 2>&1 || die "zstd is not on PATH; releases are .tar.zst and this node cannot make one" \
                                       "zstd 不在 PATH 上；正式版是 .tar.zst，這個節點做不出來"

STEM=swift_tar-$VERSION-$OS-$ARCH
ARCHIVE=$DIST/$STEM.tar.zst
[[ ! -e $ARCHIVE ]] || die "$ARCHIVE already exists; remove it first if you mean to replace it" \
                           "$ARCHIVE 已經存在；若真要取代它，請先自行刪除"

# ---------------------------------------------------------------------
# Stage: one top-level directory, so extracting cannot scatter files into the caller's cwd.
# 暫存：只有一個頂層目錄，解開時不會把檔案灑進呼叫端的目前目錄。
# ---------------------------------------------------------------------
STAGE=$DIST/$STEM
rm -rf -- "$STAGE"
mkdir -p -- "$STAGE"
cp -- "$BIN" "$STAGE/$BIN_NAME"
chmod 755 "$STAGE/$BIN_NAME"
cp -- "$VERSION_FILE" "$STAGE/version.txt"
cp -- LICENSE "$STAGE/swift_tar-LICENSE.txt"
cp -- README.md README.zh-TW.md "$STAGE/"
# A licence for every library the version file says is linked in statically.
# version 檔記為靜態連結的每個函式庫，都附上它的授權。
typeset -A LICENSE_OF=(zlib zlib/LICENSE zstd zstd/LICENSE libarchive libarchive/COPYING
                       xz xz/COPYING lz4 lz4/lib/LICENSE)
for lib in ${(k)LICENSE_OF}; do
  grep -qx "${lib}_linkage=static" "$VERSION_FILE" || continue
  [[ -r ${LICENSE_OF[$lib]} ]] || die "${LICENSE_OF[$lib]} is missing; $lib is linked in and its licence must ship" \
                                      "缺少 ${LICENSE_OF[$lib]}；$lib 已連結進來，它的授權必須隨附"
  cp -- "${LICENSE_OF[$lib]}" "$STAGE/$lib-${LICENSE_OF[$lib]:t}.txt"
done
if [[ $OS == windows ]]; then
  # The Swift runtime DLLs ride along, as in package_win.zsh, so the archive runs on a machine
  # without Swift. swiftc is .../Toolchains/<ver>/usr/bin/swiftc.exe: the root is five up.
  # Swift runtime DLL 一併放入，與 package_win.zsh 相同，讓封存在沒裝 Swift 的機器上也能執行。swiftc
  # 位於 .../Toolchains/<ver>/usr/bin/swiftc.exe：根目錄在其上五層。
  (( $+commands[swiftc] )) || die "swiftc not found on PATH; the runtime DLLs are found from it" \
                                  "PATH 上找不到 swiftc；runtime DLL 要靠它找"
  swift_root=${${commands[swiftc]}:A:h:h:h:h:h}
  rt_dll=( ${swift_root}/Runtimes/**/swiftCore.dll(N) )
  (( $#rt_dll == 1 )) || die "expected one Swift runtime under $swift_root/Runtimes, found ${#rt_dll}" \
                             "預期 $swift_root/Runtimes 下有一份 Swift runtime，實際找到 ${#rt_dll} 份"
  cp -- ${rt_dll[1]:h}/*.dll "$STAGE/"
fi

# Relative names from inside dist/: on Windows zstd and tar are native programs that cannot
# open an MSYS-style absolute path.
# 從 dist/ 裡以相對名稱操作：Windows 上 zstd 與 tar 是原生程式，開不了 MSYS 形式的絕對路徑。
# macOS's bsdtar stores extended attributes, ACLs and file flags as pax headers by default; the
# first rehearsal (2026-10-20) carried com.apple.provenance on every file, which other tars
# report as unknown keywords on extraction. Those flags are bsdtar's, so macOS only.
# macOS 的 bsdtar 預設把 xattr、ACL 與 file flags 存成 pax 標頭；第一次預演（2026-10-20）每個檔案
# 都帶著 com.apple.provenance，別的 tar 解開時會報不認得的關鍵字。這些旗標是 bsdtar 的，所以只在
# macOS 上加。
typeset -a TAR_OPTS=()
[[ $OS == macos ]] && TAR_OPTS=(--no-mac-metadata --no-xattrs --no-acls --no-fflags)
PACKED=$ARCHIVE
( cd -- "$DIST" && COPYFILE_DISABLE=1 tar "${TAR_OPTS[@]}" -cf - "$STEM" | zstd -19 -q -o "$STEM.tar.zst" )
rm -rf -- "$STAGE"

# ---------------------------------------------------------------------
# Verify by extracting and running, not by the archive existing.
# 以解開並執行來驗證，而不是看封存在不在。
# ---------------------------------------------------------------------
CHECK=$(mktemp -d "$DIST/.verify.XXXXXX")
trap 'rm -rf -- "$CHECK"' EXIT
( cd -- "$DIST" && zstd -dq -c "$STEM.tar.zst" ) | ( cd -- "$CHECK" && tar -xf - )
top=( "$CHECK"/*(N) )
(( ${#top} == 1 )) && [[ ${top[1]:t} == $STEM ]] || die "the archive does not hold exactly one directory $STEM" \
                                                         "封存裡不是恰好一個 $STEM 目錄"
[[ -x $CHECK/$STEM/$BIN_NAME ]] || die "the archive does not contain an executable $BIN_NAME" \
                                       "封存裡沒有可執行的 $BIN_NAME"
got=$(cd -- "$CHECK/$STEM" && "./$BIN_NAME" --version | tr -d '\r')
[[ $got == "$REPORTED" ]] || die "the extracted binary reports [$got], the source one [$REPORTED]" \
                                 "解開後的執行檔回報 [$got]，來源那個回報 [$REPORTED]"
# A binary that prints its version has only shown that it starts: it must also make and read
# an archive. A gzip round trip, from inside $CHECK with relative names.
# 印得出版本只證明它啟動得起來：它還必須做得出、讀得回一份封存。一次 gzip 往返，從 $CHECK 裡以相對
# 名稱進行。
(
  cd -- "$CHECK"
  mkdir -p probe/in probe/out
  print -r -- "pkg,license" > probe/in/a.txt
  seq 1 2000 > probe/in/b.txt
  "./$STEM/$BIN_NAME" -c --gzip -f probe/p.tar.gz -C probe/in a.txt b.txt
  "./$STEM/$BIN_NAME" -x -f probe/p.tar.gz -C probe/out
  cmp -s probe/in/a.txt probe/out/a.txt && cmp -s probe/in/b.txt probe/out/b.txt
) || die "the extracted binary could not round-trip a .tar.gz" "解開後的執行檔無法完成 .tar.gz 往返"
# And it refuses LZFSE rather than substituting something.
# 而且它拒絕 LZFSE，而不是改用別的東西。
if ( cd -- "$CHECK" && "./$STEM/$BIN_NAME" -c --bvx3-fast -f probe/l.bin -C probe/in a.txt ) >/dev/null 2>&1; then
  die "the extracted binary accepted --bvx3-fast; it is not the public build" \
      "解開後的執行檔接受了 --bvx3-fast；它不是公開版"
fi

# sha256 beside the archive, in the shape `sha256sum -c` / `shasum -a 256 -c` accept.
# 在封存旁寫 sha256，形狀是 `sha256sum -c`／`shasum -a 256 -c` 接受的那種。
if command -v sha256sum >/dev/null 2>&1; then
  ( cd -- "$DIST" && sha256sum "$STEM.tar.zst" > "$STEM.tar.zst.sha256" )
elif command -v openssl >/dev/null 2>&1; then
  ( cd -- "$DIST" && printf '%s  %s\n' "$(openssl dgst -sha256 -r "$STEM.tar.zst" | cut -d' ' -f1)" "$STEM.tar.zst" > "$STEM.tar.zst.sha256" )
else
  die "no sha256sum and no openssl; an archive without a checksum is not released" \
      "沒有 sha256sum 也沒有 openssl；沒有校驗和的封存不發布"
fi

print -r -- "$ARCHIVE"
cat -- "$DIST/$STEM.tar.zst.sha256"
print -r -- "$REPORTED"
print -r -- "verified: extracted, ran, round-tripped a .tar.gz, refused LZFSE / 已驗證：解開、執行、完成 .tar.gz 往返、拒絕 LZFSE"
