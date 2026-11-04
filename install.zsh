#!/usr/bin/env zsh
# =====================================================================
#  install.zsh -- download and install a published swift_tar release for this os/arch
#  install.zsh -- 下載並安裝符合本機 os/arch 的已發布 swift_tar
#
#    zsh install.zsh                     the latest release into ~/.local/bin / 最新版裝到 ~/.local/bin
#    zsh install.zsh 0.1.5               release v0.1.5 / 指定 v0.1.5
#    zsh install.zsh --prefix /opt/st    into /opt/st/bin / 裝到 /opt/st/bin
#    zsh install.zsh --musl              Linux: the static build, which needs no Swift runtime
#                                        Linux：靜態版，不需要 Swift runtime
#    zsh install.zsh --help              print this and do nothing / 印出這段說明
#
#  Picks swift_tar-<version>-<os>-<arch>.tar.zst for macos-{x86_64,arm64},
#  windows-{x86_64,arm64}, or linux-{x86_64,aarch64} (glibc; the Swift runtime must be installed)
#  and with --musl linux-{x86_64,aarch64}-musl (static), from the public GitHub Release, checks it
#  against its .sha256, and puts swift_tar (on Windows also the Swift runtime DLLs beside it) in
#  <prefix>/bin. These names are 0.2.0's; until 0.1.5 linux-<arch> was the musl build. The
#  repository is public, so no gh login is needed. Needs curl, zstd and tar on PATH.
#  依 macos-{x86_64,arm64}、windows-{x86_64,arm64}，或 linux-{x86_64,aarch64}（glibc；須先安裝 Swift
#  runtime），加 --musl 則為 linux-{x86_64,aarch64}-musl（靜態），從公開 GitHub Release 挑選
#  swift_tar-<版本>-<os>-<arch>.tar.zst，以其 .sha256 驗證，再把 swift_tar（Windows 上連同旁邊的 Swift
#  runtime DLL）放進 <prefix>/bin。這些是 0.2.0 的名稱；到 0.1.5 為止 linux-<arch> 是 musl 版。
#  repository 是公開的，不需要 gh 登入。需要 PATH 上有 curl、zstd 與 tar。
# =====================================================================
# Modelled on multissh's install.zsh. The checks are the ones release.zsh and publish.zsh already
# hold the archive to: the hash is recomputed here and compared, and the installed binary must
# report the version that was asked for, anchored, not by containment.
# 以 multissh 的 install.zsh 為範本。檢查沿用 release.zsh 與 publish.zsh 對封存的要求：雜湊在這裡
# 重算並比對；裝好的執行檔必須回報所要求的版本，以錨定比對，而不是包含比對。

emulate -L zsh
setopt no_unset pipe_fail errexit

case ${1:-} in
  -h|--help) sed -n '3,24p' ${0:A} | sed 's/^# \{0,2\}//'; exit 0 ;;
esac

REPO=raliclo/swift_tar
die() { print -ru2 -- "$1"; [[ -z ${2:-} ]] || print -ru2 -- "$2"; exit 1 }

# No `--` for openssl: macOS's /usr/bin/openssl is LibreSSL and rejects it (release.zsh learned
# this on 2026-10-31). macOS has shasum even without sha256sum.
# openssl 不加 `--`：macOS 的 /usr/bin/openssl 是 LibreSSL，會拒絕它（release.zsh 在 2026-10-31
# 學到的）。macOS 即使沒有 sha256sum 也有 shasum。
sha256_of() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum -- "$1")
  elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 -- "$1")
  elif command -v openssl >/dev/null 2>&1; then h=$(openssl dgst -sha256 -r "$1")
  else die "no sha256sum, shasum or openssl; an archive that cannot be checked is not installed" \
           "沒有 sha256sum、shasum 或 openssl；無法驗證的封存不安裝"; fi
  print -r -- ${h%% *}
}

VERSION="" prefix=$HOME/.local musl=""
while (( $# )); do
  case $1 in
    --prefix) (( $# >= 2 )) || die "--prefix needs a directory / --prefix 需要目錄"; prefix=$2; shift ;;
    --musl) musl=-musl ;;
    <->.<->.<->) VERSION=$1 ;;
    *) die "unknown argument: $1 (see --help) / 不認得的引數：$1（請見 --help）" ;;
  esac
  shift
done
prefix=${prefix:A}

for tool in curl zstd tar; do
  command -v $tool >/dev/null 2>&1 || die "$tool is not on PATH / PATH 上沒有 $tool"
done

# The eight platforms .github/workflows/release.yml ships, and nothing else: a name that is not
# among them has no archive to fetch, and saying so here is clearer than a 404 later.
# .github/workflows/release.yml 出貨的八個平台，僅此八個：不在其中的名稱沒有封存可抓，在這裡說清楚
# 勝過之後的 404。
exe=""
case $(uname -s) in
  Darwin) arch=$(uname -m)
          # Rosetta: an x86_64 shell on Apple silicon still wants the arm64 build.
          # Rosetta：Apple silicon 上的 x86_64 shell 仍應安裝 arm64 版本。
          [[ $(sysctl -n sysctl.proc_translated 2>/dev/null || true) == 1 ]] && arch=arm64
          plat=macos-$arch ;;
  Linux)  case $(uname -m) in
            x86_64|amd64)  plat=linux-x86_64$musl ;;
            aarch64|arm64) plat=linux-aarch64$musl ;;
            *)             plat=linux-$(uname -m)$musl ;;
          esac ;;
  # The machine's architecture from the system's PROCESSOR_ARCHITECTURE in the registry: MSYS2
  # emulated on arm64 says x86_64 in uname -m, and PowerShell's OSArchitecture said X64 inside
  # that emulation on the windows-11-arm runner (2026-11-04).
  # 架構取自登錄檔裡系統的 PROCESSOR_ARCHITECTURE：在 arm64 上以模擬執行的 MSYS2，uname -m 會說
  # x86_64，而在 windows-11-arm runner 的那種模擬裡，PowerShell 的 OSArchitecture 也說 X64（2026-11-04）。
  MINGW*|MSYS*|CYGWIN*)
          exe=.exe
          case $(MSYS2_ARG_CONV_EXCL='*' reg query 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' \
                   /v PROCESSOR_ARCHITECTURE | tr -d '\r' | awk '$1 == "PROCESSOR_ARCHITECTURE" { print $3 }') in
            AMD64) plat=windows-x86_64 ;;
            ARM64) plat=windows-arm64 ;;
            *)     plat=windows-$(uname -m) ;;
          esac ;;
  *) die "unsupported OS: $(uname -s) / 不支援的作業系統：$(uname -s)" ;;
esac
[[ -z $musl || $plat == linux-* ]] || die "--musl is for Linux only / --musl 只用於 Linux"
case $plat in
  macos-x86_64|macos-arm64|windows-x86_64|windows-arm64) ;;
  linux-x86_64|linux-aarch64|linux-x86_64-musl|linux-aarch64-musl) ;;
  *) die "no release for $plat; releases cover {linux,linux-musl,macos,windows} on x86_64 and arm64" \
         "沒有 $plat 的 release；正式版涵蓋 x86_64 與 arm64 上的 linux、linux-musl、macos、windows" ;;
esac

# The latest tag from where github.com/<repo>/releases/latest redirects, which needs no API token
# and no JSON parsing.
# 最新的 tag 取自 github.com/<repo>/releases/latest 轉址的目的地，不需要 API token，也不必解析 JSON。
if [[ -z $VERSION ]]; then
  latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
    || die "cannot reach github.com to find the latest release / 連不上 github.com，找不到最新版"
  VERSION=${latest##*/v}
  [[ $VERSION == <->.<->.<-> ]] || die "the latest release redirects to [$latest], which names no vX.Y.Z" \
                                       "最新版轉址到 [$latest]，其中沒有 vX.Y.Z"
fi

base=swift_tar-$VERSION-$plat.tar.zst
stem=${base%.tar.zst}
url=https://github.com/$REPO/releases/download/v$VERSION/$base
print -r -- "swift_tar $VERSION ($plat) -> $prefix/bin / 安裝 swift_tar $VERSION（$plat）到 $prefix/bin"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/swift_tar-install.XXXXXX")
trap 'rm -rf -- "${tmp:?}"' EXIT
# Relative names from inside $tmp: on Windows zstd and tar are native programs that cannot open an
# MSYS-style absolute path (the same reason release.zsh works inside dist/).
# 在 $tmp 裡以相對名稱操作：Windows 上 zstd 與 tar 是原生程式，開不了 MSYS 形式的絕對路徑（與
# release.zsh 在 dist/ 裡操作的理由相同）。
cd -- "$tmp"
curl -fsSL -o "$base" "$url" && curl -fsSL -o "$base.sha256" "$url.sha256" \
  || die "cannot download $url (is v$VERSION published?)" "無法下載 $url（v$VERSION 有發布嗎？）"

want=$(cut -d' ' -f1 < "$base.sha256")
got=$(sha256_of "$base")
[[ $want =~ '^[0-9a-f]{64}$' ]] || die "$base.sha256 holds [$want], not a sha256" "$base.sha256 裡是 [$want]，不是 sha256"
[[ $got == $want ]] || die "$base: sha256 $got does not match its .sha256 ($want)" \
                           "$base：sha256 $got 與 .sha256（$want）不符"

zstd -dq -c "$base" | tar -xf -
[[ -f $stem/swift_tar$exe ]] || die "$base has no $stem/swift_tar$exe" "$base 裡沒有 $stem/swift_tar$exe"

# Run the extracted copy before installing it, so a binary that does not start (or is not the
# version asked for) never replaces a working one.
# 安裝前先執行解出的副本，讓起不來（或版本不對）的執行檔不會取代一個能用的。
check_version() {
  local reported hint="" hint_zh=""
  # The glibc build loads the Swift runtime from the system; without it, say what to do instead.
  # glibc 版從系統載入 Swift runtime；沒有它時，說明該怎麼做。
  if [[ $plat == linux-x86_64 || $plat == linux-aarch64 ]]; then
    hint=" (the glibc build needs the Swift runtime installed; or use --musl for the static build)"
    hint_zh="（glibc 版需要先安裝 Swift runtime；或改用 --musl 安裝靜態版）"
  fi
  reported=$(cd -- "$1" && "./swift_tar$exe" --version | tr -d '\r') \
    || die "$1/swift_tar$exe does not run$hint" "$1/swift_tar$exe 無法執行$hint_zh"
  [[ $reported == "swift_tar $VERSION "* ]] || die "$1/swift_tar$exe reports [$reported], expected [swift_tar $VERSION ...]" \
                                                   "$1/swift_tar$exe 回報 [$reported]，預期是 [swift_tar $VERSION ...]"
  print -r -- "$reported"
}
check_version "$tmp/$stem" >/dev/null

# Each file is copied beside its destination and then renamed over it. Copying straight over a
# binary rewrites it in place: on macOS a signed binary changed that way is killed at its next
# start, and on Windows a running swift_tar.exe is locked, so the rename fails rather than leaving
# a half-installed set.
# 每個檔案先複製到目的地旁邊，再改名蓋過去。直接覆寫執行檔是就地改寫：macOS 上這樣改過的已簽章執行
# 檔下次啟動會被砍掉；Windows 上執行中的 swift_tar.exe 被鎖住，改名會失敗，而不是留下裝了一半的組合。
typeset -a files=("$stem/swift_tar$exe")
[[ -n $exe ]] && files+=("$stem"/*.dll(N))
mkdir -p -- "$prefix/bin"
for f in $files; do
  cp -- "$f" "$prefix/bin/${f:t}.new.$$"
  mv -f -- "$prefix/bin/${f:t}.new.$$" "$prefix/bin/${f:t}" \
    || die "cannot replace $prefix/bin/${f:t} (is swift_tar running?)" "無法取代 $prefix/bin/${f:t}（swift_tar 還在執行？）"
done
chmod 755 "$prefix/bin/swift_tar$exe"

check_version "$prefix/bin"
[[ ":$PATH:" == *":$prefix/bin:"* ]] || print -r -- "Add $prefix/bin to PATH. / 請把 $prefix/bin 加入 PATH。"
