#!/usr/bin/env zsh
# test_release.zsh -- the release tooling: build_id.zsh, release.zsh, publish_rewrite.zsh, the
# early refusals of publish.zsh, and the --version line of the built binary.
# test_release.zsh -- 出貨工具：build_id.zsh、release.zsh、publish_rewrite.zsh、publish.zsh 的前段
# 拒絕，以及建出的執行檔的 --version 行。
#
#   ./test/test_release.zsh
#
# release.zsh runs in a throwaway git repository holding a stand-in binary, so its refusals can
# each be provoked without a real build; publish_rewrite.zsh runs on copies of the real
# Formula/swift_tar.rb and bucket/swift_tar.json. Nothing here tags, pushes or publishes.
# release.zsh 在一個用完即丟、放著替身執行檔的 git repo 裡跑，不必真的建置就能逐一觸發它的拒絕；
# publish_rewrite.zsh 在真實 Formula/swift_tar.rb 與 bucket/swift_tar.json 的複本上跑。這裡不打
# tag、不推送、不發布。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,15p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
HERE="${script_path:h}"
ROOT="${HERE:h}"
case "$(uname -s)" in
  Darwin) OS=macos; PLAT=mac; ST="$ROOT/release/swift_tar" ;;
  Linux)  OS=linux; PLAT=linux; ST="$ROOT/release/swift_tar" ;;
  MSYS*|MINGW*|CYGWIN*) OS=windows; PLAT=win; ST="$ROOT/release/swift_tar.exe" ;;
  *) echo "error: unknown platform $(uname -s)" >&2; exit 1 ;;
esac
ARCH=$(uname -m)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/.test_release.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3], got [$2])"; fi; }
quiet_git() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------
# build_id.zsh
# ---------------------------------------------------------------------
. "$ROOT/build_id.zsh"
B=$TMP/bid
mkdir -p "$B"
( cd "$B" && quiet_git init -q && print a > a.txt && print v > version-mac.txt && quiet_git add . && quiet_git commit -qm one )
short=$(cd "$B" && git rev-parse --short=8 HEAD)
check "build id, untagged: the 8-character commit" "$(swift_tar_build_id "$B")" "$short"
# A chpwd hook that prints, as an interactive shell may have: build_id.zsh's directory changes
# must not run it, or its output joins the captured `git status` and a clean tree reads dirty.
# 一個會印東西的 chpwd hook，互動 shell 可能就有：build_id.zsh 切換目錄時不得執行它，否則它的輸出會
# 混進擷取到的 `git status`，乾淨的工作區會被讀成 dirty。
# Both shapes: a chpwd hook, and `cd` itself redefined as a function (the shape that was met).
# 兩種形狀都測：chpwd hook，以及 `cd` 本身被重新定義成函式（實際遇到的是這一種）。
chpwd() { print -r -- "hook: $PWD" }
cd() { builtin cd "$@" && print -r -- "listing: $PWD" }
check "build id: a printing chpwd hook or cd function does not make a clean tree dirty" "$(swift_tar_build_id "$B")" "$short"
unfunction chpwd cd
( cd "$B" && quiet_git tag -a v0.1.0 -m v0.1.0 )
check "build id, at a tag: the tag and the commit" "$(swift_tar_build_id "$B")" "v0.1.0 / $short"
print changed >> "$B/version-mac.txt"
check "build id: a rewritten version-*.txt does not make it dirty" "$(swift_tar_build_id "$B")" "v0.1.0 / $short"
print changed >> "$B/a.txt"
check "build id: any other tracked change does" "$(swift_tar_build_id "$B")" "v0.1.0 / $short-dirty"
( cd "$B" && quiet_git commit -qam two )
short2=$(cd "$B" && git rev-parse --short=8 HEAD)
check "build id, after the tag: describe's form" "$(swift_tar_build_id "$B")" "v0.1.0-1-g$short2"
rc=0; SWIFT_TAR_BUILD_ID="v0.1.0 / 00000000" swift_tar_build_id "$B" >/dev/null 2>&1 || rc=$?
check "build id: an inherited SWIFT_TAR_BUILD_ID that disagrees with git is refused" "$rc" 1
mkdir -p "$TMP/nogit"
check "build id outside git, nothing passed: unknown" "$(swift_tar_build_id "$TMP/nogit")" unknown
check "build id outside git: SWIFT_TAR_BUILD_ID" "$(SWIFT_TAR_BUILD_ID="v0.1.0 / 12345678" swift_tar_build_id "$TMP/nogit")" "v0.1.0 / 12345678"

# ---------------------------------------------------------------------
# The built binary's --version: `swift_tar <VERSION> (<build id>) <stamp>`.
# 建出的執行檔的 --version：`swift_tar <VERSION> (<build id>) <戳記>`。
# ---------------------------------------------------------------------
if [ -x "$ST" ]; then
  line=$("$ST" --version | tr -d '\r')
  if [[ $line == "swift_tar $(<"$ROOT/VERSION") ("?*") "<->-<-> ]]; then ok "--version is swift_tar <VERSION> (<id>) <stamp>: $line"
  else bad "--version is swift_tar <VERSION> (<id>) <stamp> (got [$line])"; fi
else
  bad "--version: $ST is not built"
fi

# ---------------------------------------------------------------------
# release.zsh, in a throwaway repository with a stand-in binary.
# release.zsh，在用完即丟的 repo 裡，以替身執行檔進行。
# ---------------------------------------------------------------------
# Not on Windows: there release.zsh wants a PE swift_tar.exe whose imports reach swiftCore.dll,
# plus the Swift runtime licences, and a #!/bin/sh stand-in can be neither. The Windows-only part
# of release.zsh is covered by the win_dlls cases below and by a release rehearsal on Windows.
# Windows 上不跑：那裡 release.zsh 要的是 import 能走到 swiftCore.dll 的 PE swift_tar.exe 與 Swift
# runtime 授權，#!/bin/sh 替身兩者都當不了。release.zsh 只屬 Windows 的部分由下面的 win_dlls 案例與
# 在 Windows 上的發行預演涵蓋。
if [ "$OS" = windows ]; then
  echo "SKIP: release.zsh native cases (the stand-in binary is a shell script, not a PE; see win_dlls below)"
elif [ "$OS" = linux ]; then
  # Not on glibc Linux either: since f19c63a (2026-10-20) a Linux release is the static musl
  # build made on the Mac, and release.zsh refuses a native one before reading anything else.
  # Until 2026-10-23 these cases still ran here and failed nine times on WSL, all with that
  # refusal. What is left to test here is the refusal itself.
  # glibc Linux 上也不跑：自 f19c63a（2026-10-20）起，Linux 正式版是 Mac 上建的靜態 musl 版，
  # release.zsh 在讀任何東西之前就拒絕原生打包。2026-10-23 之前這些案例仍在此執行，於 WSL 上
  # 失敗九次，全都是那個拒絕。這裡剩下要測的就是拒絕本身。
  echo "SKIP: release.zsh native cases (Linux releases are the musl cross build; see the cross cases below)"
  L=$TMP/linrel
  mkdir -p "$L"
  cp "$ROOT/release.zsh" "$ROOT/build_id.zsh" "$ROOT/platform.zsh" "$L/"
  rc=0; ( cd "$L" && unset SWIFT_TAR_PLATFORM && zsh ./release.zsh ) > "$TMP/lin.out" 2>&1 || rc=$?
  check "release.zsh: a native glibc Linux release is refused and points to the musl build" \
        "$rc:$(grep -c 'Linux releases are the static musl build made on the Mac' "$TMP/lin.out")" "1:1"
elif ! command -v zstd >/dev/null 2>&1; then
  echo "SKIP: release.zsh cases (no zstd on PATH)"
else
  R=$TMP/rel
  mkdir -p "$R/release" "$R/zlib"
  cp "$ROOT/release.zsh" "$ROOT/build_id.zsh" "$ROOT/platform.zsh" "$R/"
  print 0.1.0 > "$R/VERSION"
  print 'licence' > "$R/LICENSE"; print 'readme' > "$R/README.md"; print 'readme' > "$R/README.zh-TW.md"
  print 'zlib licence' > "$R/zlib/LICENSE"
  print -l 'swift_tar_version=20260101-000000' 'zlib_linkage=static' 'lzfse2=excluded' > "$R/version-$PLAT.txt"
  print -l '/release/' '/dist/' > "$R/.gitignore"
  ( cd "$R" && quiet_git init -q && quiet_git add . && quiet_git commit -qm rel )
  # Without an attribute on a staged file, the pax-header check below cannot fail. Measured: it
  # passed against the release.zsh that still wrote them.
  # 被打包的檔案若沒有屬性，下面的 pax 標頭檢查就不可能失敗。實測：它對仍會寫出 pax 標頭的
  # release.zsh 也通過了。
  [ "$OS" = macos ] && xattr -w com.example.swift_tar_test 1 "$R/README.md"
  # make_fake <version> <id> [accept-anything]: answers --version, and does a gzip round trip
  # through the system tar; any other option fails unless asked to accept it. The LZFSE flag is
  # never written out here, because release.zsh searches the binary for it.
  # make_fake <版本> <id> [全部接受]：回答 --version，並經由系統 tar 做 gzip 往返；其他選項一律失敗，
  # 除非要求它全部接受。LZFSE 的旗標不寫在這裡，因為 release.zsh 會在執行檔裡搜尋它。
  make_fake() {
    print -l '#!/bin/sh' \
      "if [ \"\$1\" = --version ]; then echo 'swift_tar $1 ($2) 20260101-000000'; exit 0; fi" \
      'if [ "$1" = -c ] && [ "$2" = --gzip ]; then f=$4; d=$6; shift 6; exec tar -czf "$f" -C "$d" "$@"; fi' \
      'if [ "$1" = -x ]; then exec tar -xzf "$3" -C "$5"; fi' \
      "exit ${3:-1}" > "$R/release/swift_tar"
    chmod 755 "$R/release/swift_tar"
  }
  rel() { rc=0; ( cd "$R" && ./release.zsh ) > "$TMP/rel.out" 2>&1 || rc=$?; }
  says() { grep -qF -- "$1" "$TMP/rel.out"; }
  STEM=swift_tar-0.1.0-$OS-$ARCH
  id=$(swift_tar_build_id "$R")

  make_fake 0.1.0 "$id"
  rel
  check "release.zsh: a clean public build is packaged" "$rc" 0
  if [ -s "$R/dist/$STEM.tar.zst" ] && [ -s "$R/dist/$STEM.tar.zst.sha256" ]; then ok "release.zsh: archive and .sha256 are in dist/"
  else bad "release.zsh: archive and .sha256 are in dist/ ($(tr '\n' '|' < "$TMP/rel.out"))"; fi
  if [ -s "$R/dist/$STEM.tar.zst" ]; then
    want=$(cd "$R/dist" && { sha256sum "$STEM.tar.zst" 2>/dev/null || openssl dgst -sha256 -r "$STEM.tar.zst" | sed 's/ \*/  /'; } | cut -d' ' -f1)
    check "release.zsh: the .sha256 is the archive's" "$(cut -d' ' -f1 < "$R/dist/$STEM.tar.zst.sha256")" "$want"
    listing=$(zstd -dq -c "$R/dist/$STEM.tar.zst" | tar -tf - | sed 's:/$::' | sort | tr '\n' ' ')
    check "release.zsh: one directory holding the binary, version.txt and the licences" "$listing" \
      "$STEM $STEM/README.md $STEM/README.zh-TW.md $STEM/swift_tar $STEM/swift_tar-LICENSE.txt $STEM/version.txt $STEM/zlib-LICENSE.txt "
    # No pax headers: on macOS they carried com.apple.provenance on every file, which other
    # tars report on extraction. The fixture's README.md is given an attribute on macOS (see
    # the setup), so a regression shows there; elsewhere this passes either way.
    # 沒有 pax 標頭：在 macOS 上它們讓每個檔案都帶著 com.apple.provenance，別的 tar 解開時會回報。
    # 在 macOS 上夾具的 README.md 會被加上一個屬性（見設定處），所以回歸會在那裡現形；其他平台這項
    # 怎樣都會通過。
    pax=$(zstd -dq -c "$R/dist/$STEM.tar.zst" | LC_ALL=C grep -a -c 'PaxHeader' || true)
    check "release.zsh: no pax headers (xattrs, ACLs, file flags) in the archive" "$pax" 0
  fi
  rel
  check "release.zsh: an existing archive is not overwritten" "$rc" 1
  rm -rf "$R/dist"

  rel_refuses() {   # rel_refuses <what> <text in the refusal>
    rel
    if [ "$rc" = 1 ] && says "$2" && [ ! -e "$R/dist/$STEM.tar.zst" ]; then ok "release.zsh refuses $1"
    else bad "release.zsh refuses $1 (rc $rc; $(tr '\n' '|' < "$TMP/rel.out"))"; fi
    rm -rf "$R/dist"
  }
  make_fake 0.2.0 "$id";            rel_refuses "a binary whose version is not VERSION's" "expected [swift_tar 0.1.0 ("
  make_fake 0.1.0 "v0.1.0 / 0123abcd"; rel_refuses "a binary built from another commit" "rebuild before releasing"
  make_fake 0.1.0 "$id" 0;          rel_refuses "a binary that accepts the LZFSE flag" "not the public build"
  make_fake 0.1.0 "$id"
  print '# bvx3' >> "$R/release/swift_tar"; rel_refuses "a binary containing LZFSE format names" "bvx3/other3"
  make_fake 0.1.0 "$id"
  cp "$R/version-$PLAT.txt" "$TMP/vf"
  print -l 'swift_tar_version=20260101-000000' 'zlib_linkage=static' 'lzfse2_commit=0123456789' > "$R/version-$PLAT.txt"
  rel_refuses "the full build (LZFSE compiled in)" "lzfse2=excluded"
  print 'xz_linkage=static' >> "$TMP/vf.xz"; cat "$TMP/vf" "$TMP/vf.xz" > "$R/version-$PLAT.txt"
  rel_refuses "a static library whose licence is missing" "xz/COPYING"
  cp "$TMP/vf" "$R/version-$PLAT.txt"
  print more >> "$R/LICENSE"
  rel_refuses "a dirty tree" "not clean"
  ( cd "$R" && git checkout -q -- LICENSE )
  rc=0; ( cd "$R" && ./release.zsh --nope ) >/dev/null 2>&1 || rc=$?
  check "release.zsh refuses an argument" "$rc" 2
fi

# ---------------------------------------------------------------------
# release.zsh for a musl cross target, which it checks from the file. The stand-in is a small
# static aarch64 C program carrying the identity text, built with the Static Linux SDK's
# sysroot; without the SDK and the swift.org toolchain this part is skipped.
# release.zsh 處理 musl 交叉目標，它從檔案檢查。替身是一個帶著 identity 文字的小型靜態 aarch64 C
# 程式，用 Static Linux SDK 的 sysroot 建出；沒有 SDK 與 swift.org toolchain 時這一段略過。
# ---------------------------------------------------------------------
XTC=${SWIFT_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain}/usr/bin
XSDK=( ${SWIFT_STATIC_SDK:-$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle/swift-6.4.0-RELEASE_static-linux-0.1.0/swift-linux-musl}/musl-*.sdk/aarch64(N/) )
if [ "$OS" != macos ] || [ ! -x "$XTC/clang" ] || (( ${#XSDK} != 1 )) || ! command -v zstd >/dev/null 2>&1; then
  echo "SKIP: release.zsh cross cases (needs macOS, the swift.org toolchain, the Static Linux SDK and zstd)"
else
  X=$TMP/cross
  mkdir -p "$X/release/linux-aarch64" "$X/zlib"
  cp "$ROOT/release.zsh" "$ROOT/build_id.zsh" "$ROOT/platform.zsh" "$X/"
  print 0.1.0 > "$X/VERSION"
  print 'licence' > "$X/LICENSE"; print 'readme' > "$X/README.md"; print 'readme' > "$X/README.zh-TW.md"
  print 'zlib licence' > "$X/zlib/LICENSE"
  cp -R "$ROOT/licenses" "$X/"
  print -l 'swift_tar_version=20260101-000000' 'zlib_linkage=static' 'lzfse2=excluded' \
    'swift_stdlib_linkage=static' 'libc=musl-1.2.5' > "$X/version-musl-aarch64.txt"
  print -l '/release/' '/dist/' > "$X/.gitignore"
  ( cd "$X" && quiet_git init -q && quiet_git add . && quiet_git commit -qm cross )
  xid=$(swift_tar_build_id "$X")
  xcc() {   # xcc <identity text> -- the stand-in binary
    print -r -- "const char id[] = \"$1\"; int main(void) { return id[0] == 0; }" > "$TMP/x.c"
    "$XTC/clang" --target=aarch64-unknown-linux-musl --sysroot="${XSDK[1]}" \
      -resource-dir "${XSDK[1]}/usr/lib/swift/clang" -fuse-ld=lld -rtlib=compiler-rt -static \
      "$TMP/x.c" -o "$X/release/linux-aarch64/swift_tar"
  }
  xrel() { rc=0; ( cd "$X" && SWIFT_TAR_PLATFORM=musl-aarch64 ./release.zsh ) > "$TMP/x.out" 2>&1 || rc=$?; }
  XSTEM=swift_tar-0.1.0-linux-aarch64
  xcc "swift_tar 0.1.0 ($xid)"
  xrel
  if [ "$rc" = 0 ] && [ -s "$X/dist/$XSTEM.tar.zst" ] && [ -s "$X/dist/$XSTEM.tar.zst.sha256" ] && grep -q 'NOT RUN here' "$TMP/x.out"; then
    ok "release.zsh, cross: a static aarch64 binary carrying its identity is packed as $XSTEM and marked not run"
  else
    bad "release.zsh, cross: packs $XSTEM and marks it not run (rc $rc; $(tr '\n' '|' < "$TMP/x.out"))"
  fi
  # Every third-party licence in licenses/ ships in a Linux archive: the static musl binary links
  # all of them in (licenses/README.md).
  # licenses/ 裡的每一份第三方授權都隨 Linux 封存出貨：靜態 musl 執行檔把它們全部連入（licenses/README.md）。
  # msvc-redist-NOTICE.txt is Windows-only (Visual C++ runtime DLLs). / 只屬 Windows。
  want=$(cd "$ROOT/licenses" && print -l *.txt | grep -v -x 'msvc-redist-NOTICE.txt' | sort | tr '\n' ' ')
  got=$(zstd -dq -c "$X/dist/$XSTEM.tar.zst" | tar -tf - | sed -n "s:^$XSTEM/::p" | grep -E -v '^(swift_tar|version\.txt|README.*|swift_tar-LICENSE\.txt|zlib-LICENSE\.txt)?$' | sort | tr '\n' ' ')
  check "release.zsh, cross: the archive carries every licence in licenses/" "$got" "$want"
  rm -rf "$X/dist"
  # A licence missing from a committed tree is refused, and nothing is left in dist/.
  # 已提交的樹裡少了一份授權就拒絕，dist/ 也不留東西。
  ( cd "$X" && quiet_git rm -q licenses/musl-COPYRIGHT.txt && quiet_git commit -qm 'drop musl licence' )
  xcc "swift_tar 0.1.0 ($(swift_tar_build_id "$X"))"
  xrel
  if [ "$rc" = 1 ] && grep -q 'licenses/musl-COPYRIGHT.txt is missing' "$TMP/x.out" && [ ! -e "$X/dist/$XSTEM.tar.zst" ]; then ok "release.zsh, cross: a missing licence file is refused"
  else bad "release.zsh, cross: a missing licence file is refused (rc $rc; $(tr '\n' '|' < "$TMP/x.out"))"; fi
  rm -rf "$X/dist"
  xcc "swift_tar 0.1.0 (0123abcd)"
  xrel
  if [ "$rc" = 1 ] && grep -q 'does not carry' "$TMP/x.out" && [ ! -e "$X/dist/$XSTEM.tar.zst" ]; then ok "release.zsh, cross: a binary without this checkout's identity is refused"
  else bad "release.zsh, cross: a binary without this checkout's identity is refused (rc $rc; $(tr '\n' '|' < "$TMP/x.out"))"; fi
  rm -rf "$X/dist"
  rc=0; ( cd "$X" && SWIFT_TAR_PLATFORM=musl-sparc ./release.zsh ) > "$TMP/x.out" 2>&1 || rc=$?
  check "release.zsh, cross: an unknown SWIFT_TAR_PLATFORM is refused" "$rc" 1
fi

# ---------------------------------------------------------------------
# win_dlls.zsh: which runtime DLLs the Windows archive carries, with a stand-in objdump that
# prints <pe>.imports as llvm-objdump's "DLL Name:" lines (CRLF, as on Windows).
# win_dlls.zsh：Windows 封存帶哪些 runtime DLL。替身 objdump 把 <pe>.imports 印成 llvm-objdump 的
# 「DLL Name:」行（CRLF，與 Windows 上相同）。
# ---------------------------------------------------------------------
source "$ROOT/win_dlls.zsh"
W=$TMP/win
mkdir -p "$W/rt"
for d in swiftCore.dll Foundation.dll FoundationXML.dll msvcp140.dll vcruntime140.dll concrt140.dll; do : > "$W/rt/$d"; done
: > "$W/swift_tar.exe"
print -l KERNEL32.dll swiftCore.dll Foundation.dll > "$W/swift_tar.exe.imports"
print -l swiftCore.dll MSVCP140.dll api-ms-win-crt-runtime-l1-1-0.dll > "$W/rt/Foundation.dll.imports"
print -l VCRUNTIME140.dll KERNEL32.dll > "$W/rt/swiftCore.dll.imports"
print -l libxml2.dll concrt140.dll > "$W/rt/FoundationXML.dll.imports"
print -l '#!/bin/zsh' '[[ -r $2.imports ]] || exit 0' \
  'while IFS= read -r l; do printf "    DLL Name: %s\r\n" "$l"; done < "$2.imports"' > "$W/objdump"
chmod 755 "$W/objdump"
got=$(swift_tar_win_dlls "$W/objdump" "$W/swift_tar.exe" "$W/rt" | sed "s:^$W/rt/::" | sort | tr '\n' ' ')
check "win_dlls: only the import closure ships, under the directory's own spelling" "$got" \
  "Foundation.dll msvcp140.dll swiftCore.dll vcruntime140.dll "
# The notice decision must not depend on order (2026-10-20: it shipped only when an MSVC DLL came
# first). / 附說明與否不得取決於順序（2026-10-20：只有 MSVC DLL 排第一時才附）。
rc=0; swift_tar_ships_msvc_runtime "$W/rt/Foundation.dll" "$W/rt/swiftCore.dll" "$W/rt/msvcp140.dll" || rc=$?; check "win_dlls: an MSVC DLL that comes last still counts" "$rc" 0
rc=0; swift_tar_ships_msvc_runtime "$W/rt/Foundation.dll" "$W/rt/VCRUNTIME140.DLL" || rc=$?; check "win_dlls: an upper-case MSVC name counts" "$rc" 0
rc=0; swift_tar_ships_msvc_runtime "$W/rt/Foundation.dll" "$W/rt/swiftCore.dll" || rc=$?; check "win_dlls: no MSVC DLL, no notice" "$rc" 1

# ---------------------------------------------------------------------
# publish_rewrite.zsh on copies of the real package files.
# publish_rewrite.zsh，在真實套件檔的複本上跑。
# ---------------------------------------------------------------------
FORMULA_SRC=$ROOT/Formula/swift_tar.rb
MANIFEST_SRC=${SWIFT_TAR_SCOOP_MANIFEST:-$ROOT/../bucket/swift_tar.json}
if [ ! -r "$MANIFEST_SRC" ]; then
  echo "SKIP: scoop manifest cases ($MANIFEST_SRC is not here; it lives in the parent lzfse2 repository)"
fi
P=$TMP/pub
mkdir -p "$P"
cp "$FORMULA_SRC" "$P/swift_tar.rb"
[ -r "$MANIFEST_SRC" ] && cp "$MANIFEST_SRC" "$P/swift_tar.json"
H1=$(printf 'a%.0s' {1..64}); H2=$(printf 'b%.0s' {1..64})
# Each rewrite runs in a subshell, as publish.zsh's die exits.
# 每次改寫都在子 shell 裡跑，因為 publish.zsh 的 die 會結束行程。
rw() {   # rw <version> <function> <args...>
  ( VERSION=$1; base_url=https://github.com/raliclo/swift_tar/releases/download/v$1
    say() { print -r -- "$1" }; die() { print -ru2 -- "$1"; exit 1 }
    . "$ROOT/publish_rewrite.zsh"; "${@:2}" ) > "$TMP/rw.out" 2>&1
}
# The version the Formula is at now, not a literal: this was 0.1.0, and once the Formula
# moved to 0.1.1 the first rewrite left the file holding both, which rewrite_version rightly
# refuses (2026-10-22 review). The history comment names it too, so that leaving the comment
# alone is something the rewrite could get wrong.
# Formula 目前的版本，而不是寫死的字面：這裡原本是 0.1.0，Formula 進到 0.1.1 之後，第一次改寫
# 讓檔案同時含有兩個版本，而 rewrite_version 正確地拒絕了（2026-10-22 審查）。history 註解也寫
# 這個版本，「註解保持不動」才是改寫有可能做錯的事。
CUR=$(sed -n 's/^  version "\(.*\)"$/\1/p' "$FORMULA_SRC")
check "Formula: its version is read" "$([[ $CUR == [0-9]*.[0-9]*.[0-9]* && $CUR != 0.2.0 ]] && print ok || print "[$CUR]")" ok
rc=0; rw "$CUR" rewrite_pair "$P/swift_tar.rb" "swift_tar-$CUR-macos-arm64.tar.zst" "$H1" || rc=$?
check "Formula: the macOS arm64 url and sha256 are rewritten" "$rc:$(grep -c "$H1" "$P/swift_tar.rb")" "0:1"
print -r -- "  # history: $CUR shipped first" >> "$P/swift_tar.rb"
rc=0; rw 0.2.0 rewrite_version "$P/swift_tar.rb" rb || rc=$?
check "Formula: every data line moves to 0.2.0" "$rc:$(grep -v '^ *#' "$P/swift_tar.rb" | grep -cF "$CUR")" "0:0"
check "Formula: the url, the version and the test line carry 0.2.0" "$(grep -c '0\.2\.0' "$P/swift_tar.rb")" 3
check "Formula: a comment naming $CUR as history is left alone" "$(grep -cF "history: $CUR shipped first" "$P/swift_tar.rb")" 1
rc=0; rw 0.2.0 rewrite_pair "$P/swift_tar.rb" swift_tar-0.2.0-macos-arm64.tar.zst "$H2" || rc=$?
check "Formula: then the new archive's hash replaces the old" "$rc:$(grep -c "$H2" "$P/swift_tar.rb"):$(grep -c "$H1" "$P/swift_tar.rb")" "0:1:0"
# Through a temp file: GNU grep refuses to append to its own input ("input file is also the
# output", exit 2), which ended this script on Windows; BSD grep allows it.
# 經由暫存檔：GNU grep 拒絕附加到自己的輸入（「input file is also the output」，exit 2），在 Windows
# 上讓這支腳本中途結束；BSD grep 允許。
grep '^  url ' "$P/swift_tar.rb" > "$TMP/url.line"
cat "$TMP/url.line" >> "$P/swift_tar.rb"
rc=0; rw 0.2.0 rewrite_pair "$P/swift_tar.rb" swift_tar-0.2.0-macos-arm64.tar.zst "$H1" || rc=$?
check "Formula: two urls for one platform are refused" "$rc:$(grep -c 'expected one url' "$TMP/rw.out")" "1:1"
# A two-digit major: the old glob read "10.2.3" as "0.2.3", rewrote it to "110.2.4" and then died
# on its own leftover check -- after gh release create, so the release was already public.
# 兩位數的主版號：舊的 glob 把 "10.2.3" 讀成 "0.2.3"，改寫成 "110.2.4" 後被自己的殘留檢查擋下——
# 而那發生在 gh release create 之後，release 已經公開。
sed "s/$CUR/10.2.3/g" "$FORMULA_SRC" > "$P/ten.rb"
rc=0; rw 10.2.4 rewrite_version "$P/ten.rb" rb || rc=$?
check "Formula: a two-digit major version is read whole" "$rc:$(grep -c '110\.2\.4' "$P/ten.rb"):$(grep -c '10\.2\.4' "$P/ten.rb")" "0:0:3"
if [ -r "$P/swift_tar.json" ]; then
  rc=0; rw 0.2.0 rewrite_version "$P/swift_tar.json" json || rc=$?
  check "scoop: version, url and extract_dir move to 0.2.0" "$rc:$(grep -c '0\.2\.0' "$P/swift_tar.json")" "0:3"
  check "scoop: the autoupdate template keeps its literal \$version" "$(grep -c 'v$version/swift_tar-$version-windows-x86_64' "$P/swift_tar.json")" 1
  rc=0; rw 0.2.0 rewrite_pair "$P/swift_tar.json" swift_tar-0.2.0-windows-x86_64.tar.zst "$H2" || rc=$?
  check "scoop: the Windows hash is rewritten, the template left alone" "$rc:$(grep -c "$H2" "$P/swift_tar.json")" "0:1"
  # sed alone, not grep | sed: with no match grep exits 1 and pipefail ended the script here,
  # instead of failing this one case (seen on Windows with a stale parent manifest).
  # 只用 sed，不用 grep | sed：沒有比對到時 grep exit 1，pipefail 會在這裡結束腳本，而不是只讓這一項
  # 失敗（在 Windows 上以過舊的上層套件檔遇到）。
  extract=$(sed -n 's/.*"extract_dir": "\(swift_tar-0[^"]*\)".*/\1/p' "$P/swift_tar.json")
  check "scoop: extract_dir names the archive's directory" "$extract" swift_tar-0.2.0-windows-x86_64
fi

# ---------------------------------------------------------------------
# publish.zsh: the refusals before anything outward-facing.
# publish.zsh：碰任何對外東西之前的拒絕。
# ---------------------------------------------------------------------
rc=0; "$ROOT/publish.zsh" 0.1 >/dev/null 2>&1 || rc=$?
check "publish.zsh refuses a two-part version" "$rc" 2
rc=0; "$ROOT/publish.zsh" --publish >/dev/null 2>&1 || rc=$?
check "publish.zsh refuses an option where the version goes" "$rc" 2
rc=0; out=$("$ROOT/publish.zsh" 9.9.9 2>&1) || rc=$?
if [ "$rc" = 1 ] && [[ $out == *"VERSION says"* ]]; then ok "publish.zsh refuses a version that is not VERSION's"
else bad "publish.zsh refuses a version that is not VERSION's (rc $rc: $out)"; fi
# An unpushed commit on a detached HEAD, which is what building at a tag looks like. The old guard
# asked `rev-list @{upstream}..HEAD 2>/dev/null`; a detached HEAD has no upstream, so it printed
# nothing and let the commit through. Run in a clone whose origin is this repository, so the
# fetch stays local and the commit never reaches it. Only the refusal is tested: past the guard
# publish.zsh goes on to gh.
# detached HEAD 上一個未推送的 commit——在 tag 上建置就是這個樣子。舊的檢查問的是
# `rev-list @{upstream}..HEAD 2>/dev/null`；detached HEAD 沒有 upstream，於是什麼都不印，讓那個
# commit 通過。在一個 origin 指向本 repo 的 clone 裡跑，fetch 留在本機，commit 也不會到達本 repo。
# 只測拒絕：通過這道檢查之後 publish.zsh 會接著去碰 gh。
# A fake gh comes first on PATH, so that a guard that regressed stops at "gh is not
# authenticated" instead of reaching GitHub. / PATH 最前面放一個假的 gh，退化的檢查就會停在
# 「gh 尚未登入」，而不會碰到 GitHub。
if [ -r "$MANIFEST_SRC" ]; then
  mkdir -p "$TMP/fakebin"
  printf '#!/bin/sh\necho "fake gh: $*" >&2\nexit 1\n' > "$TMP/fakebin/gh"; chmod +x "$TMP/fakebin/gh"
  C=$TMP/pubclone
  git clone -q --shared "$ROOT" "$C"
  git -C "$C" checkout -q --detach
  # The unpushed commit carries this tree's publish.zsh, so it is the script under test that
  # runs, not the committed one. / 未推送的 commit 帶著本工作區的 publish.zsh，所以跑的是受測的
  # 腳本，而不是已提交的那份。
  cp "$ROOT/publish.zsh" "$C/publish.zsh"
  git -C "$C" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -am unpushed
  rc=0; out=$(PATH="$TMP/fakebin:$PATH" SWIFT_TAR_SCOOP_MANIFEST=$MANIFEST_SRC "$C/publish.zsh" "$(<"$C/VERSION")" 2>&1) || rc=$?
  if [ "$rc" = 1 ] && [[ $out == *"HEAD is on no origin branch"* ]]; then ok "publish.zsh refuses an unpushed commit on a detached HEAD"
  else bad "publish.zsh refuses an unpushed commit on a detached HEAD (rc $rc: $out)"; fi
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
