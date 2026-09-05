#!/usr/bin/env zsh
# test/test_strip_components.zsh -- verify --strip-components extraction semantics.
# test/test_strip_components.zsh -- 驗證 --strip-components 解出語意。
#
#   ./test/test_strip_components.zsh          run the suite against release/swift_tar
#                                             以 release/swift_tar 執行測試
#   ./test/test_strip_components.zsh --help   print this synopsis and exit
#                                             印出本說明後結束
set -euo pipefail

# Answered above the reference-tar probe below, which creates a temp dir.
# 在下方會建立暫存目錄的參照 tar 探測之前回答。
script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,8p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
if [ ! -x "$ST" ]; then
  echo "error: build first — missing swift_tar release binary" >&2
  exit 1
fi

# 參考用的 tar 由實測選出，而不是假設 `tar` 這個名字就等於可用的實作。理由與
# test_blind_findings.zsh 相同：Buildroot guest 的 /usr/bin/tar 只支援 `-f -`（串流），
# 對 `-f <檔案>` 直接拒絕，於是這支測試在該節點上是敗在參考封存從未被建立，而不是敗在
# --strip-components 的行為。
#
# The reference tar is chosen by measurement rather than by assuming the name
# `tar` is a usable implementation, for the same reason as in
# test_blind_findings.zsh: the Buildroot guest's /usr/bin/tar takes only `-f -`
# and refuses `-f <file>`, so this test failed there because the reference
# archive was never created, not because of anything --strip-components did.
if [ -z "${SYS_TAR:-}" ]; then
  probe="$(mktemp -d)"
  : > "$probe/f"
  for candidate in tar bsdtar; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if ( cd "$probe" && "$candidate" -cf probe.tar f ) >/dev/null 2>&1 && [ -s "$probe/probe.tar" ]; then
      SYS_TAR="$candidate"
      break
    fi
    rm -f "$probe/probe.tar"
  done
  rm -rf "$probe"
fi
if [ -z "${SYS_TAR:-}" ]; then
  echo "error: no reference tar can write an archive (tried tar, bsdtar) / 找不到能寫出封存的參考 tar" >&2
  exit 1
fi
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
# device:inode 同樣改用 zsh 內建的 zsh/stat。原本先試 GNU 的 `stat -c` 再退回 BSD 的
# `stat -f`——那涵蓋 Linux 與 macOS，卻涵蓋不了「沒有 stat」：Buildroot guest 的 applet
# 清單裡根本沒有它，於是兩個分支都失敗，而第二個沒有 `2>/dev/null`，錯誤會直接噴出。
# device:inode also comes from zsh's own zsh/stat. This used to try GNU's
# `stat -c` and fall back to BSD's `stat -f`, which covers Linux and macOS but
# not "no stat at all": it is absent from the Buildroot guest's applet list, so
# both branches failed and the second one, unredirected, spilled its error.
zmodload zsh/stat
inode_of() {
  local -A entry
  zstat -H entry -- "$1" 2>/dev/null || return 1
  print -- "${entry[device]}:${entry[inode]}"
}
must_fail() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

SRC="$TMP/src"
mkdir -p "$SRC/top/dir" "$SRC/top/empty"
printf 'alpha\n' > "$SRC/top/dir/a.txt"
printf 'bravo\n' > "$SRC/top/dir/b.txt"
HARDLINK_EXPECTED=1
ln "$SRC/top/dir/a.txt" "$SRC/top/dir/a-hard.txt" 2>/dev/null || {
  HARDLINK_EXPECTED=0
  cp "$SRC/top/dir/a.txt" "$SRC/top/dir/a-hard.txt"
}
"$SYS_TAR" -cf "$TMP/nested.tar" -C "$SRC" top

mkdir -p "$TMP/out1"
"$ST" -x --strip-components=1 -f "$TMP/nested.tar" -C "$TMP/out1"
[ -f "$TMP/out1/dir/a.txt" ] && [ -f "$TMP/out1/dir/b.txt" ] && [ ! -e "$TMP/out1/top" ] \
  && cmp -s "$SRC/top/dir/a.txt" "$TMP/out1/dir/a.txt" \
  && cmp -s "$SRC/top/dir/b.txt" "$TMP/out1/dir/b.txt" \
  && ok "--strip-components=1 removes the top directory" \
  || bad "--strip-components=1 extraction layout/content"
if [ "$HARDLINK_EXPECTED" -eq 1 ]; then
  [ "$(inode_of "$TMP/out1/dir/a.txt")" = "$(inode_of "$TMP/out1/dir/a-hard.txt")" ] \
    && ok "--strip-components=1 preserves hardlinks" \
    || bad "--strip-components=1 hardlink preservation"
fi

mkdir -p "$TMP/out2"
"$ST" -x --strip-components 2 -f "$TMP/nested.tar" -C "$TMP/out2"
[ -f "$TMP/out2/a.txt" ] && [ -f "$TMP/out2/b.txt" ] && [ ! -e "$TMP/out2/dir" ] \
  && cmp -s "$SRC/top/dir/a.txt" "$TMP/out2/a.txt" \
  && ok "--strip-components 2 accepts separate numeric argument" \
  || bad "--strip-components 2 extraction layout/content"

mkdir -p "$TMP/out3"
"$ST" -x --strip-components=99 -f "$TMP/nested.tar" -C "$TMP/out3"
if find "$TMP/out3" -mindepth 1 -print | grep -q .; then
  bad "--strip-components skips entries stripped to empty"
else
  ok "--strip-components skips entries stripped to empty"
fi

must_fail "--strip-components rejects negative values" \
  "$ST" -x --strip-components=-1 -f "$TMP/nested.tar" -C "$TMP/bad"
must_fail "--strip-components requires a value" \
  "$ST" -x --strip-components -f "$TMP/nested.tar" -C "$TMP/bad"
must_fail "--strip-components is extract-only" \
  "$ST" -t --strip-components=1 -f "$TMP/nested.tar"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
