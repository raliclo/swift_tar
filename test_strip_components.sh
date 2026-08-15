#!/usr/bin/env zsh
# test_strip_components.sh -- verify --strip-components extraction semantics.
# test_strip_components.sh -- 驗證 --strip-components 解出語意。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
  esac
fi
if [ ! -x "$ST" ]; then
  echo "error: build first — missing swift_tar release binary" >&2
  exit 1
fi

SYS_TAR="${SYS_TAR:-tar}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
inode_of() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"; }
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
