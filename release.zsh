#!/usr/bin/env zsh
# =====================================================================
#  release.zsh -- package THIS platform's public swift_tar build as one .tar.zst
#  release.zsh -- 把這個平台的公開版 swift_tar 打包成一份 .tar.zst
#
#    ./release.zsh                                  this machine's build / 這台機器的建置
#    SWIFT_TAR_PLATFORM=musl-aarch64 ./release.zsh  a Linux build made on the Mac / Mac 上建的 Linux 版
#    ./release.zsh --help                           print this and do nothing / 印出這段說明
#
#  After the public build (no LZFSE): macOS ./compile_tar.zsh --no-lzfse; Windows
#  EXCLUDE_LZFSE=1 zsh ./compile_tar-win.zsh; Linux, on the Mac, ./compile_tar-musl.zsh <arch>,
#  checked from the file here and run on a Linux machine with ./verify_release.zsh. The
#  others are run where they were built. Publishing is publish.zsh's job.
#  先建公開版（不含 LZFSE）：macOS ./compile_tar.zsh --no-lzfse；Windows EXCLUDE_LZFSE=1 zsh
#  ./compile_tar-win.zsh；Linux 在 Mac 上 ./compile_tar-musl.zsh <arch>，在這裡從檔案檢查，再到 Linux
#  機器上以 ./verify_release.zsh 執行。其餘的在建置處執行。發布是 publish.zsh 的事。
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

# Which build: this machine's own, or a musl cross target named by SWIFT_TAR_PLATFORM (made by
# compile_tar-musl.zsh on the Mac; the Linux releases are those, decided 2026-10-20). A cross
# binary cannot run here, so it is checked from the file and run later on a Linux machine of
# its architecture with verify_release.zsh.
# 哪一份建置：這台機器自己的，或由 SWIFT_TAR_PLATFORM 指名的 musl 交叉目標（compile_tar-musl.zsh 在
# Mac 上建出；Linux 正式版就是這兩份，2026-10-20 決定）。交叉建置的執行檔在這裡跑不了，所以從檔案
# 檢查，之後再以 verify_release.zsh 在同架構的 Linux 機器上執行。
. "$HERE/platform.zsh"
PLAT=$(swift_tar_platform) || die "unknown SWIFT_TAR_PLATFORM" "不認得的 SWIFT_TAR_PLATFORM"
CROSS=0
case $PLAT in
  musl-aarch64|musl-x86_64)
    CROSS=1; OS=linux; ARCH=${PLAT#musl-}; BIN_NAME=swift_tar ;;
  mac) OS=macos;   ARCH=$(uname -m) ;;
  win) OS=windows; ARCH=$(uname -m) ;;
  linux) die "Linux releases are the static musl build made on the Mac: ./compile_tar-musl.zsh <arch>, then SWIFT_TAR_PLATFORM=musl-<arch> ./release.zsh" \
             "Linux 正式版是在 Mac 上建的靜態 musl 版：./compile_tar-musl.zsh <arch>，再 SWIFT_TAR_PLATFORM=musl-<arch> ./release.zsh" ;;
  *) die "unknown platform $PLAT" "不認得的平台 $PLAT" ;;
esac
if (( CROSS )); then
  BIN=$HERE/release/linux-$ARCH/swift_tar
  [[ -f $BIN ]] || die "no $BIN; run ./compile_tar-musl.zsh $ARCH first" "沒有 $BIN；請先執行 ./compile_tar-musl.zsh $ARCH"
else
  if [[ -x release/swift_tar.exe ]]; then BIN_NAME=swift_tar.exe
  elif [[ -x release/swift_tar ]]; then BIN_NAME=swift_tar
  else die "no built binary in release/; build the public build first (see --help)" \
           "release/ 裡沒有已建置的執行檔；請先建公開版（見 --help）"; fi
  BIN=$HERE/release/$BIN_NAME
fi
VERSION_FILE=$HERE/version-$PLAT.txt
[[ -r $VERSION_FILE ]] || die "$VERSION_FILE is missing; the build writes it" "缺少 $VERSION_FILE；建置會寫出它"
VERSION=$(<VERSION)

# The tree must be clean apart from the version files the build rewrites, or the archive's id
# names a state other than what was packaged. Same exemption as build_id.zsh.
# 除了建置會改寫的 version 檔之外，工作區必須乾淨，否則封存上的 id 指的是別的狀態。與 build_id.zsh
# 的豁免相同。
if [[ -e $HERE/.git ]]; then
  dirty=$(git status --porcelain --untracked-files=no -- . ':(exclude)version-*.txt')
  [[ -z $dirty ]] || { print -ru2 -- "$dirty"; die "the working tree is not clean; an archive built from it would carry an id that describes something else" \
                                                   "工作區不乾淨；由它產生的封存會帶著一個描述別的東西的 id"; }
fi

# The id the binary carries must be the one this checkout gives now.
# 執行檔帶的 id 必須等於這個 checkout 現在給的 id。
source "$HERE/build_id.zsh"
EXPECTED_ID=$(swift_tar_build_id "$HERE")
[[ $EXPECTED_ID != unknown ]] || die "no build id: not a git checkout and SWIFT_TAR_BUILD_ID is not set" \
                                     "沒有 build id：這不是 git checkout，也沒有設定 SWIFT_TAR_BUILD_ID"
[[ $EXPECTED_ID != *-dirty ]] || die "the build id is $EXPECTED_ID; a release is built from a clean tree" \
                                     "build id 是 $EXPECTED_ID；正式版要從乾淨的工作區建置"
IDENTITY="swift_tar $VERSION ($EXPECTED_ID)"

# ---------------------------------------------------------------------
# What the binary says it is: asked by running it, or, for a cross build, found in it -- the
# number and the id are one literal (generate_version.zsh), so the text is there verbatim.
# 執行檔說它是什麼：靠執行它問出來；交叉建置的則在檔案裡找——版本號與 id 是同一個字面值
# （generate_version.zsh），所以那段文字原樣在裡面。
# ---------------------------------------------------------------------
if (( CROSS )); then
  hits=$(LC_ALL=C grep -a -c -F -- "$IDENTITY" "$BIN" || true)
  [[ $hits != 0 ]] || die "$BIN does not carry [$IDENTITY]; rebuild with ./compile_tar-musl.zsh $ARCH" \
                          "$BIN 裡沒有 [$IDENTITY]；請以 ./compile_tar-musl.zsh $ARCH 重新建置"
  REPORTED=$IDENTITY
  # Static, ELF, and the architecture its name will claim.
  # 靜態、ELF，而且是它的名稱將宣稱的那個架構。
  kind=$(file -b "$BIN")
  [[ $kind == ELF*statically\ linked* ]] || die "$BIN is not a static ELF executable: $kind" "$BIN 不是靜態 ELF 執行檔：$kind"
  case $ARCH in aarch64) want='*aarch64*' ;; x86_64) want='*x86-64*' ;; esac
  [[ $kind == ${~want} ]] || die "$BIN is not $ARCH: $kind" "$BIN 不是 $ARCH：$kind"
  grep -qx 'swift_stdlib_linkage=static' "$VERSION_FILE" && grep -q '^libc=musl-' "$VERSION_FILE" \
    || die "$VERSION_FILE does not record a static musl build" "$VERSION_FILE 沒有記錄為靜態 musl 建置"
else
  # `swift_tar <X.Y.Z> (<build id>) <stamp>`; a native Windows program is asked from inside
  # release/ with a bare name, as it cannot open an MSYS-style absolute path. Anchored on the
  # whole identity: containment would let `v0.1.0-13-g...` pass as `v0.1.0`.
  # `swift_tar <X.Y.Z> (<build id>) <戳記>`；原生 Windows 程式從 release/ 裡以裸檔名問，因為它開不了
  # MSYS 形式的絕對路徑。以整段 identity 錨定：用包含比對會讓 `v0.1.0-13-g...` 被當成 `v0.1.0`。
  REPORTED=$(cd release && "./$BIN_NAME" --version | tr -d '\r')
  [[ $REPORTED == "$IDENTITY "* ]] || die "the binary reports [$REPORTED], expected [$IDENTITY ...] (VERSION and this checkout); rebuild before releasing" \
                                          "執行檔回報 [$REPORTED]，預期是 [$IDENTITY ...]（VERSION 與這個 checkout）；發行前請重新建置"
fi

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
# Third-party licences kept in licenses/ (see licenses/README.md for versions and sources): the
# Swift runtime set wherever that runtime ships with the binary -- linked in on Linux, DLLs beside
# it on Windows -- and on Linux also the rest of what the static musl SDK links in. macOS uses the
# system's Swift and libbz2, so it takes none.
# licenses/ 裡的第三方授權（版本與來源見 licenses/README.md）：凡 Swift runtime 隨執行檔出貨之處
# ——Linux 連入、Windows 以 DLL 附在旁邊——都帶 runtime 那一組；Linux 另帶靜態 musl SDK 連入的其餘
# 元件。macOS 用系統的 Swift 與 libbz2，所以不帶。
typeset -a SWIFT_RUNTIME_LICENSES=(swift-LICENSE swift-experimental-string-processing-LICENSE
  swift-corelibs-foundation-LICENSE swift-foundation-LICENSE swift-foundation-icu-LICENSE
  icu-LICENSE swift-corelibs-libdispatch-LICENSE)
typeset -a THIRD_PARTY=()
if (( CROSS )); then
  THIRD_PARTY=($SWIFT_RUNTIME_LICENSES musl-COPYRIGHT musl-fts-COPYING bzip2-LICENSE
               llvm-libcxx-LICENSE llvm-libcxxabi-LICENSE llvm-libunwind-LICENSE llvm-compiler-rt-LICENSE)
elif [[ $OS == windows ]]; then
  THIRD_PARTY=($SWIFT_RUNTIME_LICENSES)
fi
for name in $THIRD_PARTY; do
  [[ -r licenses/$name.txt ]] || die "licenses/$name.txt is missing; it ships with every $OS archive" \
                                     "缺少 licenses/$name.txt；每份 $OS 封存都必須附上它"
  cp -- "licenses/$name.txt" "$STAGE/$name.txt"
done
if [[ $OS == windows ]]; then
  # The Swift runtime DLLs ride along, as in package_win.zsh, so the archive runs on a machine
  # without Swift. Chosen the way compile_tar-win.zsh chooses the runtime it builds against: the
  # newest under %LOCALAPPDATA%\Programs\Swift\Runtimes by zsh's numeric glob order, so during an
  # upgrade, when two sit side by side (6.4.0 and 6.4.1 did on 2026-10-19), the archive carries
  # the one the binary was built for rather than failing or taking the older.
  # Swift runtime DLL 一併放入，與 package_win.zsh 相同，讓封存在沒裝 Swift 的機器上也能執行。選法
  # 與 compile_tar-win.zsh 選它建置所用的 runtime 相同：%LOCALAPPDATA%\Programs\Swift\Runtimes 下依 zsh
  # 數字 glob 排序最新的那份。升級期間兩份並存時（2026-10-19 的 6.4.0 與 6.4.1 就是），封存帶的是執行
  # 檔所對應的那份，而不是失敗或拿到較舊的。
  swift_root="$(cygpath -u "${LOCALAPPDATA:-$HOME/AppData/Local}")/Programs/Swift"
  found=("$swift_root"/Runtimes/*/usr/bin(/Nn))
  rt_bin=${found[-1]:-}
  [[ -n $rt_bin && -f $rt_bin/swiftCore.dll ]] || die "no Swift runtime with swiftCore.dll under $swift_root/Runtimes" \
                                                      "$swift_root/Runtimes 下找不到含 swiftCore.dll 的 Swift runtime"
  cp -- "$rt_bin"/*.dll "$STAGE/"
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
# By the machine packing, not by the target: the Linux archives are packed on the Mac too.
# 依打包的機器判斷，不依目標：Linux 封存也是在 Mac 上打包的。
[[ $(uname -s) == Darwin ]] && TAR_OPTS=(--no-mac-metadata --no-xattrs --no-acls --no-fflags)
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
if (( CROSS )); then
  # It cannot run here: the extracted file must be the checked one, byte for byte, and the
  # running is verify_release.zsh's on a Linux machine of this architecture.
  # 它在這裡跑不了：解開的檔案必須與檢查過的那一份逐位元組相同，執行則交給同架構 Linux 機器上的
  # verify_release.zsh。
  cmp -s "$CHECK/$STEM/$BIN_NAME" "$BIN" || die "the extracted binary differs from $BIN" "解開後的執行檔與 $BIN 不同"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd -- "$DIST" && sha256sum "$STEM.tar.zst" > "$STEM.tar.zst.sha256" )
  else
    ( cd -- "$DIST" && printf '%s  %s\n' "$(openssl dgst -sha256 -r "$STEM.tar.zst" | cut -d' ' -f1)" "$STEM.tar.zst" > "$STEM.tar.zst.sha256" )
  fi
  print -r -- "$ARCHIVE"
  cat -- "$DIST/$STEM.tar.zst.sha256"
  print -r -- "$REPORTED"
  print -r -- "checked from the file (static $ARCH ELF, identity inside, extracted byte-identical); NOT RUN here -- run ./verify_release.zsh $STEM.tar.zst on a linux-$ARCH machine"
  print -r -- "已從檔案檢查（靜態 $ARCH ELF、內含 identity、解開後逐位元組相同）；這裡沒有執行——請在 linux-$ARCH 機器上執行 ./verify_release.zsh $STEM.tar.zst"
  exit 0
fi
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
