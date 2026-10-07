#!/usr/bin/env zsh
# test_skip_compressed.zsh -- `-c --skip-compressed` writes one already-compressed file
# without the codec, and changes nothing else.
# test_skip_compressed.zsh -- `-c --skip-compressed` 對單一已壓縮檔案不套用 codec，其餘一律不變。
#
#   ./test/test_skip_compressed.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_skip_compressed.zsh    # a specific binary
#
# Each case is judged by the archive's own bytes, not by its name or size: a zstd stream
# starts with 28 b5 2f fd, a tar has "ustar" at offset 257, a ZIP starts with "PK". The
# suffix list is alreadyCompressedSuffixes in swift_tar.swift and the README section
# "Already-compressed suffixes".
# 每一項都以封存本身的位元組判定，不看檔名或大小：zstd 串流以 28 b5 2f fd 開頭，tar 在位移
# 257 有 "ustar"，ZIP 以 "PK" 開頭。後綴清單見 swift_tar.swift 的 alreadyCompressedSuffixes
# 與 README 的「已壓縮的後綴」一節。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,15p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
HERE="${script_path:h}"
ROOT="${HERE:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }

# What the archive is, from its bytes: zstd, tar, zip, or "other" (also for a missing file).
# 依位元組判定封存的種類：zstd、tar、zip，或 "other"（檔案不存在時亦同）。
kind_of() {
  [ -s "$1" ] || { echo other; return; }
  local magic; magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
  case $magic in
    28b52ffd) echo zstd; return ;;
    504b*)    echo zip; return ;;
  esac
  if [ "$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null)" = ustar ]; then echo tar; else echo other; fi
}

mkdir -p "$TMP/src/dir.zip"
head -c 300000 /dev/urandom > "$TMP/src/movie.zip"
head -c 300000 /dev/urandom > "$TMP/src/CLIP.MP4"
head -c 300000 /dev/urandom > "$TMP/src/other.zip"
print -r -- "plain text" > "$TMP/src/note.txt"
print -r -- "inside" > "$TMP/src/dir.zip/f.txt"

# create <archive> <flags/operands...> ; runs in $TMP/src, stderr kept in <archive>.err
# 在 $TMP/src 中建立；stderr 存於 <archive>.err
create() {
  local out=$1; shift
  ( cd "$TMP/src" && "$ST" -c "$@" -f "$out" ) >/dev/null 2>"$out.err" || true
}

create "$TMP/a1" --zstd --skip-compressed movie.zip
eq "single .zip with --skip-compressed: written as plain tar" tar "$(kind_of "$TMP/a1")"
case $(cat "$TMP/a1.err") in
  *"already compressed"*) ok "single .zip with --skip-compressed: says so on stderr" ;;
  *) bad "single .zip with --skip-compressed: says so on stderr" ;;
esac
mkdir -p "$TMP/x1" "$TMP/x2"
"$ST" -x -f "$TMP/a1" -C "$TMP/x1" >/dev/null 2>&1 || true
if cmp -s "$TMP/src/movie.zip" "$TMP/x1/movie.zip"; then ok "it extracts to the original bytes"
else bad "it extracts to the original bytes"; fi
# The receiving side may still pass --zstd: reading auto-detects.
# 接收端仍可傳 --zstd：讀取時自動偵測。
"$ST" -x --zstd -f "$TMP/a1" -C "$TMP/x2" >/dev/null 2>&1 || true
if cmp -s "$TMP/src/movie.zip" "$TMP/x2/movie.zip"; then ok "-x --zstd still extracts it"
else bad "-x --zstd still extracts it"; fi

create "$TMP/a2" --zstd --skip-compressed CLIP.MP4
eq "suffix match ignores case (.MP4)" tar "$(kind_of "$TMP/a2")"

create "$TMP/a3" --zstd movie.zip
eq "without the flag: still zstd" zstd "$(kind_of "$TMP/a3")"

create "$TMP/a4" --zstd --skip-compressed note.txt
eq "suffix not in the list: still zstd" zstd "$(kind_of "$TMP/a4")"

create "$TMP/a5" --zstd --skip-compressed movie.zip other.zip
eq "two files: still zstd" zstd "$(kind_of "$TMP/a5")"

create "$TMP/a6" --zstd --skip-compressed dir.zip
eq "a directory named *.zip: still zstd" zstd "$(kind_of "$TMP/a6")"

( cd "$TMP" && "$ST" -c --zstd --skip-compressed -C src -f "$TMP/a7" movie.zip ) >/dev/null 2>&1 || true
eq "with -C: the file is found under it" tar "$(kind_of "$TMP/a7")"

( cd "$TMP/src" && "$ST" -c --zstd --skip-compressed -f - movie.zip ) > "$TMP/a8" 2>/dev/null || true
eq "to stdout (-f -): written as plain tar" tar "$(kind_of "$TMP/a8")"

create "$TMP/a9" --zip --skip-compressed movie.zip
eq "--zip is a container, not a stream codec: still ZIP" zip "$(kind_of "$TMP/a9")"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
