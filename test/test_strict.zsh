#!/usr/bin/env zsh
# test_strict.zsh -- `-x` exits non-zero when it skips a member, unless --no-strict.
# test_strict.zsh -- `-x` 略過成員時以非 0 結束，除非給了 --no-strict。
#
#   ./test/test_strict.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_strict.zsh    # a specific binary
#
# Until 2026-10-08 a skipped member left the exit status at 0, so a caller judging by the
# status alone -- multissh does -- reported a transfer complete when files had not landed.
# The user decided: strict by default, --no-strict for the old behaviour, a member refused
# for an unsafe path counts, and a member left out by --exclude does not (the caller asked
# for it). Every case here makes a skip actually happen and checks three things: the exit
# status, that stderr counts the skipped members, and that the other members still land --
# strict reports at the end, it does not stop early.
#
# 在 2026-10-08 之前，略過成員時退出碼維持 0，所以只看退出碼的呼叫端——multissh 就是——
# 會在檔案沒有落地時回報傳輸完成。使用者決定：預設嚴格，--no-strict 回到舊行為；因不安全路徑
# 而被拒絕的成員算失敗，--exclude 排除的不算（那是呼叫端要求的）。這裡每一項都讓略過真的發生，
# 並檢查三件事：退出碼、stderr 有計數、其餘成員照常落地——嚴格模式是在結束時回報，不會提早停止。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,23p' "$script_path" | sed 's/^# \{0,1\}//'
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
SYS_TAR=${SYS_TAR:-tar}

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# extract <label> <archive> <expect: fail|zero> <must-exist file> [flags...]
# Runs -x into a fresh directory and checks the status, the stderr count and that the
# member that should land did.
# 解到一個新目錄，檢查退出碼、stderr 的計數，以及應該落地的成員是否落地。
extract() {
  local label=$1 arc=$2 expect=$3 must=$4; shift 4
  local out="$TMP/out.$label" rc=0
  rm -rf "$out"; mkdir -p "$out"
  [ -n "${PREP:-}" ] && $PREP "$out"
  "$ST" -x "$@" -f "$arc" -C "$out" >/dev/null 2>"$out.err" || rc=$?
  if [ "$expect" = fail ]; then
    if [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ]; then ok "$label: exits non-zero ($rc)"
    else bad "$label: exits non-zero (got $rc)"; fi
    case $(cat "$out.err") in
      *"skipped"*) ok "$label: stderr counts the skipped members" ;;
      *) bad "$label: stderr counts the skipped members" ;;
    esac
  else
    [ "$rc" -eq 0 ] && ok "$label: exits 0" || bad "$label: exits 0 (got $rc; $(head -c 200 "$out.err"))"
  fi
  [ -f "$out/$must" ] && ok "$label: the other member still lands" \
    || bad "$label: the other member still lands ($must missing)"
}

# ---- fixtures / 測試資料 ----
mkdir -p "$TMP/src/sub" "$TMP/src/real" "$TMP/other/l"
print -r -- ok > "$TMP/src/sub/ok.txt"
print -r -- escape > "$TMP/src/escape.txt"
# 1. an unsafe path: "../escape.txt" stored as is (-P keeps it).
#    不安全路徑：以 -P 原樣存入 "../escape.txt"。
( cd "$TMP/src/sub" && "$SYS_TAR" -cPf "$TMP/unsafe.tar" ok.txt ../escape.txt ) >/dev/null 2>&1 || true
# 2. through a symlink: member "l" is a symlink, then member "l/f" -- written through it
#    would land outside -C.
#    穿過 symlink：成員 "l" 是 symlink，其後的成員 "l/f" 若經它寫入會落在 -C 之外。
ln -s ../elsewhere "$TMP/src/l"
( cd "$TMP/src" && "$SYS_TAR" -cf "$TMP/link.tar" sub/ok.txt l ) >/dev/null 2>&1 || true
print -r -- through > "$TMP/other/l/f"
( cd "$TMP/other" && "$SYS_TAR" -rf "$TMP/link.tar" l/f ) >/dev/null 2>&1 || true
# 3. a parent that cannot be created: the destination holds a read-only directory "ro" and
#    the member is "ro/sub/f".
#    無法建立的上層目錄：目的地有唯讀目錄 "ro"，成員是 "ro/sub/f"。
mkdir -p "$TMP/src3/ro/sub"
print -r -- f > "$TMP/src3/ro/sub/f"; print -r -- ok > "$TMP/src3/ok.txt"
( cd "$TMP/src3" && "$SYS_TAR" -cf "$TMP/perm.tar" ok.txt ro/sub/f ) >/dev/null 2>&1 || true
make_ro() { mkdir -p "$1/ro"; chmod 555 "$1/ro"; }

for f in unsafe link perm; do
  [ -s "$TMP/$f.tar" ] && ok "fixture $f.tar was built" || bad "fixture $f.tar was built"
done

extract unsafe        "$TMP/unsafe.tar" fail ok.txt
extract unsafe-nostrict "$TMP/unsafe.tar" zero ok.txt --no-strict
extract link          "$TMP/link.tar"   fail sub/ok.txt
extract link-nostrict "$TMP/link.tar"   zero sub/ok.txt --no-strict
if [ "$(id -u)" = 0 ]; then
  echo "SKIP: read-only directory cases (root ignores the permission bits)"
else
  PREP=make_ro extract perm          "$TMP/perm.tar" fail ok.txt
  PREP=make_ro extract perm-nostrict "$TMP/perm.tar" zero ok.txt --no-strict
fi
# A skip the caller asked for is not a failure. / 呼叫端要求的略過不算失敗。
extract exclude "$TMP/unsafe.tar" zero ok.txt --exclude '../escape.txt'
# Nothing skipped, nothing reported. / 沒有略過就沒有回報。
( cd "$TMP/src/sub" && "$ST" -c -f "$TMP/clean.tar" ok.txt ) >/dev/null 2>&1
extract clean "$TMP/clean.tar" zero ok.txt
[ -s "$TMP/out.clean.err" ] && bad "clean: nothing on stderr" || ok "clean: nothing on stderr"

# ZIP: the libarchive bridge skips "a/b" when "a" is a file; strict must count that too.
# Needs a bsdtar to build the fixture, as in test_blind_findings.
# ZIP：當 "a" 是檔案時，libarchive bridge 會略過 "a/b"；嚴格模式也必須算入。測試資料需要 bsdtar
# 建立，同 test_blind_findings。
ZBSD=""
for cand in "$SYS_TAR" bsdtar /c/Windows/System32/tar.exe; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version 2>&1 | grep -q bsdtar; then ZBSD=$cand; break; fi
done
if [ -n "$ZBSD" ]; then
  mkdir -p "$TMP/z/d1" "$TMP/z/d2/a"
  print -r -- A > "$TMP/z/d1/a"; print -r -- C > "$TMP/z/d1/c"; print -r -- B > "$TMP/z/d2/a/b"
  ( cd "$TMP/z" && COPYFILE_DISABLE=1 "$ZBSD" --format zip -cf "$TMP/z.zip" -C d1 a -C ../d2 a/b -C ../d1 c ) >/dev/null 2>&1 || true
  extract zip          "$TMP/z.zip" fail c
  extract zip-nostrict "$TMP/z.zip" zero c --no-strict
else
  echo "SKIP: ZIP strict cases (no bsdtar here to build the fixture)"
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
