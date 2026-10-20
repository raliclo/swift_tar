#!/usr/bin/env zsh
# =====================================================================
# verify_release.zsh -- run a Linux release archive on a Linux machine of its architecture
# verify_release.zsh -- 在同架構的 Linux 機器上執行一份 Linux 正式版封存
#
#   ./verify_release.zsh swift_tar-0.1.0-linux-aarch64.tar.zst
#   ./verify_release.zsh --help
#
# The Linux archives are built and packed on the Mac (compile_tar-musl.zsh, release.zsh),
# where they cannot run. This is the running: on a Linux machine of the archive's
# architecture it checks the .sha256 beside it, extracts it, confirms the binary is static,
# prints its --version, round-trips a .tar.gz, sees LZFSE refused, and runs the built-in
# self-tests. Needs only the archive, its .sha256, zstd and tar; no checkout.
# Linux 封存在 Mac 上建置與打包（compile_tar-musl.zsh、release.zsh），在那裡跑不了。這支腳本就是那個
# 「執行」：在與封存同架構的 Linux 機器上核對旁邊的 .sha256、解開、確認執行檔是靜態的、印出
# --version、完成一次 .tar.gz 往返、確認 LZFSE 被拒絕，並執行內建自我測試。只需要封存、它的
# .sha256、zstd 與 tar，不需要 checkout。
# =====================================================================
emulate -L zsh
setopt no_unset pipe_fail errexit extended_glob

case ${1:-} in
  -h|--help) sed -n '3,16p' ${0:A} | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') print -ru2 -- "usage: ./verify_release.zsh <archive.tar.zst> / 用法"; exit 2 ;;
esac
A=${1:A}
die() { print -ru2 -- "FAIL: $1"; [[ -z ${2:-} ]] || print -ru2 -- "失敗：$2"; exit 1 }

[[ $(uname -s) == Linux ]] || die "run this on Linux" "請在 Linux 上執行"
base=${A:t}
[[ $base == (#b)swift_tar-(<->.<->.<->)-linux-(aarch64|x86_64).tar.zst ]] \
  || die "$base is not named swift_tar-<X.Y.Z>-linux-<arch>.tar.zst" "$base 的名稱不是 swift_tar-<X.Y.Z>-linux-<arch>.tar.zst"
VERSION=$match[1] ARCH=$match[2]
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

# Static: no program interpreter. Asked of the binary, with whatever this machine has.
# 靜態：沒有 program interpreter。問執行檔本身，用這台機器上有的工具。
if command -v readelf >/dev/null 2>&1; then
  ! readelf -lW "$B" | grep -q INTERP || die "the binary has a program interpreter; it is not static" "執行檔有 program interpreter；不是靜態的"
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
print -r -- "  checks  static, ran in an empty environment, .tar.gz round trip, LZFSE refused, --crypto-selftest, -test"
