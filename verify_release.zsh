#!/usr/bin/env zsh
# =====================================================================
# verify_release.zsh -- run a Linux release archive on a Linux machine of its architecture
# verify_release.zsh -- 在同架構的 Linux 機器上執行一份 Linux 正式版封存
#
#   ./verify_release.zsh swift_tar-0.1.6-linux-aarch64-musl.tar.zst
#   ./verify_release.zsh --help
#
# The -musl archives are built and packed on the Mac (compile_tar-musl.zsh, release.zsh),
# where they cannot run. This is the running: on a Linux machine of the archive's
# architecture it checks the .sha256 beside it, extracts it, confirms the binary is static
# (-musl) or that its Swift runtime loads from the archive's lib/ (-glibc), prints its
# --version, round-trips a .tar.gz, sees LZFSE refused, and runs the built-in self-tests.
# Needs only the archive, its .sha256, zstd and tar (and readelf for -glibc); no checkout.
# -musl 封存在 Mac 上建置與打包（compile_tar-musl.zsh、release.zsh），在那裡跑不了。這支腳本就是那個
# 「執行」：在與封存同架構的 Linux 機器上核對旁邊的 .sha256、解開、確認執行檔是靜態的（-musl）或
# 它的 Swift runtime 從封存的 lib/ 載入（-glibc）、印出 --version、完成一次 .tar.gz 往返、確認
# LZFSE 被拒絕，並執行內建自我測試。只需要封存、它的 .sha256、zstd 與 tar（-glibc 另需 readelf），
# 不需要 checkout。
# =====================================================================
emulate -L zsh
setopt no_unset pipe_fail errexit extended_glob

case ${1:-} in
  -h|--help) sed -n '3,19p' ${0:A} | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') print -ru2 -- "usage: ./verify_release.zsh <archive.tar.zst> / 用法"; exit 2 ;;
esac
A=${1:A}
die() { print -ru2 -- "FAIL: $1"; [[ -z ${2:-} ]] || print -ru2 -- "失敗：$2"; exit 1 }

[[ $(uname -s) == Linux ]] || die "run this on Linux" "請在 Linux 上執行"
base=${A:t}
[[ $base == (#b)swift_tar-(<->.<->.<->)-linux-(aarch64|x86_64)-(glibc|musl).tar.zst ]] \
  || die "$base is not named swift_tar-<X.Y.Z>-linux-<arch>-<glibc|musl>.tar.zst" "$base 的名稱不是 swift_tar-<X.Y.Z>-linux-<arch>-<glibc|musl>.tar.zst"
VERSION=$match[1] ARCH=$match[2] LIBC=$match[3]
[[ $(uname -m) == $ARCH ]] || die "this machine is $(uname -m), the archive is $ARCH" "這台機器是 $(uname -m)，封存是 $ARCH"
for t in zstd tar sha256sum cmp seq; do command -v $t >/dev/null 2>&1 || die "$t is not on PATH" "PATH 上沒有 $t"; done

# The checksum the packing machine wrote, recomputed here.
# 打包機器寫下的校驗和，在這裡重算。
[[ -r $A.sha256 ]] || die "no $base.sha256 beside it" "旁邊沒有 $base.sha256"
h=$(sha256sum "$A" | cut -d' ' -f1)
[[ $h == $(awk '{print $1}' "$A.sha256") ]] || die "$base hashes to $h, its .sha256 says otherwise" "$base 算出 $h，與 .sha256 不符"

W=$(mktemp -d)
trap 'rm -rf -- "$W"' EXIT
stem=${base%.tar.zst}
( cd -- "$W" && zstd -dq -c "$A" | tar -xf - )
B=$W/$stem/swift_tar
[[ -x $B ]] || die "the archive has no executable $stem/swift_tar" "封存裡沒有可執行的 $stem/swift_tar"

# -glibc: dynamic, and every Swift runtime library resolves inside the archive's lib/, asked
# of the loader in list mode with an empty environment (as release.zsh does), so a Swift
# installed on this machine cannot stand in.
# -glibc：動態連結，且每個 Swift runtime 函式庫都解析到封存的 lib/ 裡；以空環境用列出模式問載入器
# （與 release.zsh 相同），這台機器上裝的 Swift 就頂替不了。
if [[ $LIBC == glibc ]]; then
  command -v readelf >/dev/null 2>&1 || die "readelf is not on PATH; a glibc archive is checked with it" "PATH 上沒有 readelf；glibc 封存要靠它檢查"
  segs=$(readelf -lW "$B") || die "readelf -lW failed on the binary" "readelf -lW 對執行檔失敗"
  interp=${${${(M)${(f)segs}:#*program interpreter:*}##*: }%%\]*}
  [[ -n $interp && -x $interp ]] || die "the binary's program interpreter [$interp] is not on this machine" "這台機器上沒有執行檔的 program interpreter [$interp]"
  [[ -f $W/$stem/lib/libswiftCore.so ]] || die "the archive has no $stem/lib/libswiftCore.so" "封存裡沒有 $stem/lib/libswiftCore.so"
  listing=$(env -i "$interp" --list "$B") || die "$interp --list failed on the binary" "$interp --list 對執行檔失敗"
  [[ $listing != *'not found'* ]] || die "unresolved libraries: ${(M)${(f)listing}:#*not found*}" "解析不到的函式庫：${(M)${(f)listing}:#*not found*}"
  for so in $W/$stem/lib/*.so*(N); do
    hits=(${(M)${(f)listing}:#*[[:space:]]${so:t} => *})
    [[ -n ${hits[1]-} ]] || continue
    p=${${hits[1]#* => }%% \(*}
    [[ ${p:A:h} == ${W:A}/$stem/lib ]] || die "${so:t} resolves to $p, not to the archive's lib/" "${so:t} 解析到 $p，不是封存裡的 lib/"
  done
  hits=(${(M)${(f)listing}:#*[[:space:]]libswiftCore.so => *})
  [[ -n ${hits[1]-} ]] || die "the loader does not list libswiftCore.so for the binary" "載入器沒有為執行檔列出 libswiftCore.so"
# -musl: static, no program interpreter. Asked of the binary, with whatever this machine has.
# -musl：靜態，沒有 program interpreter。問執行檔本身，用這台機器上有的工具。
elif command -v readelf >/dev/null 2>&1; then
  # readelf's own failure must fail too: `! readelf | grep -q` read an empty listing as
  # "no interpreter" (2026-10-31 review S2).
  # readelf 本身失敗也要算失敗：`! readelf | grep -q` 把空的輸出讀成「沒有 interpreter」（審查 S2）。
  segs=$(readelf -lW "$B") || die "readelf -lW failed on the binary" "readelf -lW 對執行檔失敗"
  [[ $segs != *INTERP* ]] || die "the binary has a program interpreter; it is not static" "執行檔有 program interpreter；不是靜態的"
elif command -v file >/dev/null 2>&1; then
  [[ $(file -b "$B") == *statically\ linked* ]] || die "file does not call the binary static: $(file -b "$B")" "file 不認為它是靜態的"
else
  die "neither readelf nor file is on PATH; static linkage cannot be checked" "PATH 上沒有 readelf 也沒有 file；無法檢查靜態連結"
fi

# Run with an empty environment, so nothing on this machine's library path can stand in.
# 以空環境執行，這台機器的函式庫路徑上的任何東西都無法頂替。
line=$(env -i "$B" --version)
[[ $line == "swift_tar $VERSION ("*") "* ]] || die "--version printed [$line], expected swift_tar $VERSION (<id>) <stamp>" \
                                                  "--version 印出 [$line]，預期 swift_tar $VERSION (<id>) <戳記>"
(
  cd -- "$W"
  mkdir -p in out
  print -r -- "pkg,license" > in/a.txt
  seq 1 2000 > in/b.txt
  env -i "$B" -c --gzip -f p.tar.gz -C in a.txt b.txt
  env -i "$B" -x -f p.tar.gz -C out
  cmp -s in/a.txt out/a.txt && cmp -s in/b.txt out/b.txt
) || die "the binary could not round-trip a .tar.gz" "執行檔無法完成 .tar.gz 往返"
if ( cd -- "$W" && env -i "$B" -c --bvx3-fast -f l.bin -C in a.txt ) >/dev/null 2>&1; then
  die "the binary accepted --bvx3-fast; it is not the public build" "執行檔接受了 --bvx3-fast；不是公開版"
fi
env -i "$B" --crypto-selftest >/dev/null 2>&1 || die "--crypto-selftest failed" "--crypto-selftest 失敗"
# -test compares against a standard tar on PATH, so it keeps this machine's PATH.
# -test 要和 PATH 上的標準 tar 比對，所以保留這台機器的 PATH。
( cd -- "$W" && env -i PATH="$PATH" "$B" -test ) >/dev/null 2>&1 || die "-test failed (it needs GNU tar or bsdtar on PATH)" "-test 失敗（它需要 PATH 上有 GNU tar 或 bsdtar）"

print -r -- "VERIFIED $base"
print -r -- "  sha256  $h"
print -r -- "  version $line"
print -r -- "  machine $(uname -srm)"
print -r -- "  checks  $LIBC linkage, ran in an empty environment, .tar.gz round trip, LZFSE refused, --crypto-selftest, -test"
