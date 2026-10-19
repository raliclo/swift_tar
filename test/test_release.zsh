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
if ! command -v zstd >/dev/null 2>&1; then
  echo "SKIP: release.zsh cases (no zstd on PATH)"
else
  R=$TMP/rel
  mkdir -p "$R/release" "$R/zlib"
  cp "$ROOT/release.zsh" "$ROOT/build_id.zsh" "$R/"
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
  make_fake 0.2.0 "$id";            rel_refuses "a binary whose version is not VERSION's" "VERSION says"
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
rc=0; rw 0.1.0 rewrite_pair "$P/swift_tar.rb" swift_tar-0.1.0-macos-arm64.tar.zst "$H1" || rc=$?
check "Formula: the macOS arm64 url and sha256 are rewritten" "$rc:$(grep -c "$H1" "$P/swift_tar.rb")" "0:1"
print '  # history: 0.1.0 shipped first' >> "$P/swift_tar.rb"
rc=0; rw 0.2.0 rewrite_version "$P/swift_tar.rb" rb || rc=$?
check "Formula: every data line moves to 0.2.0" "$rc:$(grep -v '^ *#' "$P/swift_tar.rb" | grep -c '0\.1\.0')" "0:0"
check "Formula: the url, the version and the test line carry 0.2.0" "$(grep -c '0\.2\.0' "$P/swift_tar.rb")" 3
check "Formula: a comment naming 0.1.0 as history is left alone" "$(grep -c 'history: 0.1.0 shipped first' "$P/swift_tar.rb")" 1
rc=0; rw 0.2.0 rewrite_pair "$P/swift_tar.rb" swift_tar-0.2.0-macos-arm64.tar.zst "$H2" || rc=$?
check "Formula: then the new archive's hash replaces the old" "$rc:$(grep -c "$H2" "$P/swift_tar.rb"):$(grep -c "$H1" "$P/swift_tar.rb")" "0:1:0"
grep '^  url ' "$P/swift_tar.rb" >> "$P/swift_tar.rb"
rc=0; rw 0.2.0 rewrite_pair "$P/swift_tar.rb" swift_tar-0.2.0-macos-arm64.tar.zst "$H1" || rc=$?
check "Formula: two urls for one platform are refused" "$rc:$(grep -c 'expected one url' "$TMP/rw.out")" "1:1"
if [ -r "$P/swift_tar.json" ]; then
  rc=0; rw 0.2.0 rewrite_version "$P/swift_tar.json" json || rc=$?
  check "scoop: version, url and extract_dir move to 0.2.0" "$rc:$(grep -c '0\.2\.0' "$P/swift_tar.json")" "0:3"
  check "scoop: the autoupdate template keeps its literal \$version" "$(grep -c 'v$version/swift_tar-$version-windows-x86_64' "$P/swift_tar.json")" 1
  rc=0; rw 0.2.0 rewrite_pair "$P/swift_tar.json" swift_tar-0.2.0-windows-x86_64.tar.zst "$H2" || rc=$?
  check "scoop: the Windows hash is rewritten, the template left alone" "$rc:$(grep -c "$H2" "$P/swift_tar.json")" "0:1"
  extract=$(grep '"extract_dir": "swift_tar-0' "$P/swift_tar.json" | sed 's/.*"extract_dir": "//; s/".*//')
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

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
