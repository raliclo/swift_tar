#!/usr/bin/env zsh
#
# build_tool_install-wsl.zsh -- install or upgrade the Swift toolchain in WSL/Linux for swift_tar
# build_tool_install-wsl.zsh -- 在 WSL／Linux 安裝或升級 swift_tar 所需的 Swift 工具鏈
#
# The Windows counterpart (build_tool_install-win.zsh) installs Swift via winget; this is the
# WSL/Linux side the two-platform build needs. It resolves the newest Swift release (or a version
# given as $1), downloads the tarball for this Ubuntu, verifies its signature, backs up the
# existing /usr/local/swift and installs the new one in its place. compile_tar-win.zsh learned on
# 2026-10-19 to pick the newest installed Swift rather than trust a stale PATH; keeping WSL on the
# same release is why this exists.
#
# 對應的 Windows 版（build_tool_install-win.zsh）以 winget 裝 Swift；這是雙平台建置所需的
# WSL／Linux 端。它解析最新 Swift（或以 $1 指定版本），下載對應本機 Ubuntu 的 tarball、驗章、
# 備份既有 /usr/local/swift，再就地安裝新版。compile_tar-win.zsh 於 2026-10-19 改為選用最新
# 安裝的 Swift 而非信任過期 PATH；讓 WSL 與其同一釋出版，正是本腳本存在的理由。
#
#   sudo zsh ./build_tool_install-wsl.zsh            # install the latest release / 安裝最新釋出版
#   sudo zsh ./build_tool_install-wsl.zsh 6.4.1      # install a specific version / 指定版本
#   zsh ./build_tool_install-wsl.zsh --help          # this synopsis, installing nothing / 僅說明
#
# Must run as root (writes /usr/local/swift). Re-running is safe: if the target version is already
# installed it does nothing. The previous toolchain is kept at /usr/local/swift.bak.<stamp> so an
# upgrade can be rolled back with a single mv.
# 需以 root 執行（寫入 /usr/local/swift）。可重複執行：若目標版本已安裝則不動作。舊工具鏈保留
# 於 /usr/local/swift.bak.<時間戳>，升級可用一次 mv 回退。
#
# It also installs the tools the test suite runs that a stock Ubuntu lacks: bsdtar
# (libarchive-tools), the reference reader of test_review_20261031.zsh. On 2026-10-31 a WSL that
# built and passed everything else FAILed two cases there with "command not found". This step
# runs even when Swift is already current, and needs root only when something is missing.
# 另外安裝整套測試會用到、而預設 Ubuntu 沒有的工具：bsdtar（libarchive-tools），
# test_review_20261031.zsh 的參考讀取器。2026-10-31 一台其他全過的 WSL，因缺它讓那裡兩個案例以
# 「command not found」FAIL。即使 Swift 已是最新也會執行；只有缺東西時才需要 root。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '3,34p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

die()  { print -ru2 -- "[FAIL] $1"; exit 1 }
note() { print -r -- "$1" }

# ---- target version / 目標版本 ----
# $1 overrides; otherwise ask GitHub for the newest release. The tag looks like
# swift-6.4.1-RELEASE; keep only the 6.4.1. / $1 可覆寫；否則向 GitHub 問最新釋出版。
if [[ -n ${1:-} ]]; then
  version=$1
else
  note "Resolving the latest Swift release from GitHub... / 向 GitHub 解析最新 Swift 釋出版..."
  json=$(curl -fsSL https://api.github.com/repos/swiftlang/swift/releases/latest) \
    || die "could not reach the GitHub releases API / 無法連上 GitHub releases API"
  tag=$(print -r -- "$json" | sed -nE 's/.*"tag_name": *"swift-([0-9.]+)-RELEASE".*/\1/p' | head -1)
  [[ -n $tag ]] || die "could not resolve the latest release tag / 無法解析最新釋出版標籤"
  version=$tag
fi
note "Target Swift version / 目標 Swift 版本: $version"

# ---- Ubuntu platform tag / Ubuntu 平台標籤 ----
# Ask the server rather than keep a list. The first version of this script listed the Ubuntu
# releases Swift publishes for, read off the install page, and sent 26.04 to the 24.04 build --
# while download.swift.org did have a native ubuntu26.04 tarball for 6.4.1 (another session on
# this machine found it the same day, 2026-10-19, by its sha256 differing from what was
# installed). So probe this machine's own VERSION_ID first, and only if that tarball is absent
# fall back through older releases, newest first, saying so.
# 問伺服器，而不是維護一份清單。本腳本第一版依安裝頁列出 Swift 發行的 Ubuntu 版本，把 26.04 送去
# 用 24.04 build——而 download.swift.org 其實有 6.4.1 的原生 ubuntu26.04 tarball（同一天
# 2026-10-19，本機另一個 session 因 sha256 與已安裝者不同而發現）。故先探測本機自己的
# VERSION_ID，只有那個 tarball 不存在時才由新到舊回退，並說明。
. /etc/os-release || die "no /etc/os-release / 找不到 /etc/os-release"
[[ $ID == ubuntu ]] || die "this installer targets Ubuntu; found ID=$ID / 本安裝器針對 Ubuntu，當前 ID=$ID"
arch=$(uname -m)   # x86_64 tarballs carry no arch suffix; aarch64 does
suffix=""
[[ $arch == aarch64 ]] && suffix="-aarch64"
tarball_url() {  # <ubuntu version> -> URL
  print -r -- "https://download.swift.org/swift-${version}-release/ubuntu${1//./}${suffix}/swift-${version}-RELEASE/swift-${version}-RELEASE-ubuntu${1}${suffix}.tar.gz"
}
# Fallbacks are only releases no newer than this one: a newer build links a newer glibc.
# 回退只考慮不比本機新的版本：較新的 build 連結較新的 glibc。
autoload -Uz is-at-least
candidates=($VERSION_ID)
for ubu in 26.04 24.04 22.04 20.04; do
  [[ $ubu != $VERSION_ID ]] && is-at-least $ubu $VERSION_ID && candidates+=($ubu)
done
url=""
for ubu in $candidates; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -I "$(tarball_url $ubu)")
  if [[ $code == 200 ]]; then url=$(tarball_url $ubu); break; fi
  [[ $ubu == $VERSION_ID ]] && note "No ubuntu$ubu tarball for Swift $version (HTTP $code); trying older builds / 找不到 Swift $version 的 ubuntu$ubu tarball（HTTP $code），改試較舊的 build"
done
[[ -n $url ]] || die "no Ubuntu tarball found for Swift $version / 找不到 Swift $version 的 Ubuntu tarball"
base=${${url:t}%.tar.gz}
note "Download URL / 下載網址: $url"

# ---- tools the test suite runs / 整套測試要用的工具 ----
# Checked by command, installed by package: what matters is whether the tests can run the name.
# Before the "already installed" exit, so a machine with a current Swift still gets them.
# 以指令檢查、以套件安裝：重點是測試能否執行那個名稱。放在「已安裝」的提前結束之前，所以 Swift
# 已是最新的機器也會補上。
test_tools=(bsdtar:libarchive-tools)
missing_pkgs=()
for pair in $test_tools; do
  command -v ${pair%%:*} >/dev/null || missing_pkgs+=(${pair#*:})
done
if (( ${#missing_pkgs} )); then
  [[ $(id -u) == 0 ]] || die "test tools missing; run as root (sudo) to install: ${missing_pkgs[*]} / 缺少測試工具，請以 root（sudo）執行以安裝：${missing_pkgs[*]}"
  note "Installing test tools / 安裝測試工具: ${missing_pkgs[*]}"
  apt-get update -q || die "apt-get update failed / apt-get update 失敗"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing_pkgs || die "apt-get install failed / apt-get install 失敗"
  for pair in $test_tools; do
    command -v ${pair%%:*} >/dev/null || die "${pair%%:*} still not on PATH after installing ${pair#*:} / 安裝 ${pair#*:} 後仍找不到 ${pair%%:*}"
  done
fi
note "[OK] test tools present / 測試工具齊全: ${test_tools%%:*}"

# ---- already installed? / 已安裝？ ----
# The version alone is not enough: the 24.04 and 26.04 builds of 6.4.1 both report 6.4.1. The
# install leaves the tarball's name in $marker and a rerun compares that too.
# 只比版本不夠：6.4.1 的 24.04 與 26.04 build 都回報 6.4.1。安裝時把 tarball 名稱留在 $marker，
# 重跑時一併比對。
target=/usr/local/swift
marker=$target/.installed-from
current=""
[[ -x $target/usr/bin/swift ]] && \
  current=$("$target/usr/bin/swift" --version | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)
installed_from=""
[[ -r $marker ]] && installed_from=$(<"$marker")
note "Currently installed / 目前已安裝: ${current:-<none>} (${installed_from:-tarball unrecorded / 未記錄來源})"
if [[ $current == $version && $installed_from == $base ]]; then
  note "[OK] $base already installed; nothing to do / 已安裝 $base，無需動作"
  exit 0
fi

# ---- root required for the install step / 安裝步驟需 root ----
[[ $(id -u) == 0 ]] || die "run as root (sudo) to write /usr/local/swift / 請以 root（sudo）執行以寫入 /usr/local/swift"

# ---- download + verify / 下載與驗章 ----
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
note "Downloading $base.tar.gz (~1-2 GB)... / 下載中..."
curl -fSL --retry 3 -o "$work/$base.tar.gz" "$url"      || die "tarball download failed / tarball 下載失敗"
curl -fSL --retry 3 -o "$work/$base.tar.gz.sig" "$url.sig" || die "signature download failed / 簽章下載失敗"

note "Importing the Swift signing keys and verifying... / 匯入 Swift 簽章金鑰並驗證..."
# --compressed is required here and only here. www.swift.org serves all-keys.asc with
# Content-Encoding: gzip even to a client that did not ask for it, and curl does not decode that
# unless told to, so gpg received gzip bytes (1f 8b 08 00) and reported "no valid OpenPGP data
# found" (2026-10-19, first run of this script). The tarball and .sig come back as plain
# application/octet-stream with no Content-Encoding, so they must stay byte-for-byte as served --
# the signature is over those exact bytes.
# 只有這裡需要 --compressed。www.swift.org 送 all-keys.asc 時即使客戶端沒要求也帶
# Content-Encoding: gzip，而 curl 未被告知就不解碼，於是 gpg 收到 gzip 位元組（1f 8b 08 00）並回報
# 「no valid OpenPGP data found」（2026-10-19，本腳本首次執行）。tarball 與 .sig 是不帶
# Content-Encoding 的純 application/octet-stream，必須保持伺服器送出的原始位元組——簽章就是對那些
# 位元組簽的。
curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --import - \
  || die "could not import Swift keys / 無法匯入 Swift 金鑰"
gpg --verify "$work/$base.tar.gz.sig" "$work/$base.tar.gz"        || die "signature verification FAILED -- not installing / 簽章驗證失敗，拒絕安裝"
note "[OK] signature verified / 簽章已驗證"

# ---- install, keeping the old one for rollback / 安裝並保留舊版以便回退 ----
if [[ -e $target ]]; then
  bak="$target.bak.$(date +%Y%m%d%H%M%S)"
  note "Backing up the existing toolchain to $bak / 備份既有工具鏈至 $bak"
  mv "$target" "$bak"
fi
mkdir -p "$target"
# --strip-components=1 drops the swift-<ver>-RELEASE-ubuntuXX/ prefix so that usr/ lands directly
# under /usr/local/swift, matching the layout the previous install and the build rpath expect.
# --strip-components=1 去掉 swift-<ver>-RELEASE-ubuntuXX/ 前綴，使 usr/ 直接落在 /usr/local/swift
# 下，與先前安裝及建置 rpath 預期的佈局一致。
note "Extracting into $target... / 解壓至 $target..."
tar -xzf "$work/$base.tar.gz" --strip-components=1 -C "$target" || die "extract failed / 解壓失敗"

# ---- verify / 驗證 ----
got=$("$target/usr/bin/swift" --version | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)
[[ $got == $version ]] || die "post-install swift reports '$got', expected '$version' / 安裝後 swift 回報 '$got'，預期 '$version'"
print -r -- "$base" > "$marker"
note "[OK] $base installed at $target / 已安裝 $base 於 $target"
note "    swift --version: $("$target/usr/bin/swift" --version | head -1)"
note "Done. Rebuild with: zsh ./build.zsh / 完成。以 zsh ./build.zsh 重建"
