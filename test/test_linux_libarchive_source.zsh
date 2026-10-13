#!/usr/bin/env zsh
# test_linux_libarchive_source.zsh -- the Linux build always takes libarchive from libarchive/.
# test_linux_libarchive_source.zsh -- Linux 建置的 libarchive 一律來自 libarchive/。
#
#   zsh test/test_linux_libarchive_source.zsh          run (Linux only) / 執行（僅 Linux）
#   zsh test/test_linux_libarchive_source.zsh --help   print this synopsis and exit / 印出說明後結束
#
# Why: compile_tar-linux.zsh used to link the sysroot's shared libarchive when cmake or the
# sources were missing, or when LIBARCHIVE_STATIC=0 said so. That binary had none of
# patch/libarchive/*.patch -- `-c --zip` could not store a FIFO and compressed on one thread
# -- and nothing built or tested it. Since 2026-10-14 there is one kind of Linux binary, as
# on macOS: the build stops instead of falling back. This checks that the old switch is
# refused without touching the binary, and that the binary at hand records and has a static
# libarchive.
# 為什麼：compile_tar-linux.zsh 以前在缺 cmake 或原始碼、或 LIBARCHIVE_STATIC=0 時，會連結
# sysroot 的共享 libarchive。那種執行檔不含任何 patch/libarchive/*.patch——`-c --zip` 存不了
# FIFO，且只用一個執行緒壓縮——而沒有任何東西建過或測過它。2026-10-14 起 Linux 與 macOS 一樣
# 只有一種執行檔：建置會停止而不是退回。這裡檢查舊的開關被拒絕且不動到執行檔，以及手上的
# 執行檔記錄著、也確實帶著靜態的 libarchive。
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,6p' "${0:A}" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT="${0:A:h:h}"
[ "$(uname -s)" = Linux ] || { echo "SKIP: compile_tar-linux.zsh is the Linux build"; exit 0; }
ST="$ROOT/release/swift_tar"
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

before=$(sha256sum "$ST" | cut -c1-64)
# The status is the assertion, so it is captured rather than left to set -e.
# 斷言的是狀態本身，所以把它存下來，而不是交給 set -e。
rc=0; ( cd "$ROOT" && LIBARCHIVE_STATIC=0 zsh ./compile_tar-linux.zsh ) > "$TMP/out" 2>&1 || rc=$?
[ "$rc" != 0 ] && ok "LIBARCHIVE_STATIC=0 is refused" || bad "LIBARCHIVE_STATIC=0 is refused (rc 0)"
grep -q 'LIBARCHIVE_STATIC=0' "$TMP/out" && ok "the refusal names the setting" \
  || bad "the refusal names the setting ($(tail -2 "$TMP/out" | tr '\n' '|'))"
[ "$(sha256sum "$ST" | cut -c1-64)" = "$before" ] && ok "the refused build left the binary alone" \
  || bad "the refused build left the binary alone"

grep -q '^libarchive_linkage=static$' "$ROOT/version-linux.txt" && ok "version-linux.txt records a static libarchive" \
  || bad "version-linux.txt records a static libarchive"
if command -v readelf >/dev/null 2>&1; then
  # grep's status 1 means no such line, which is the result wanted. / grep 以 1 結束表示沒有這種行，正是要的結果。
  needed=$(readelf -d "$ST" | grep -c 'NEEDED.*libarchive' || [ $? -eq 1 ])
  [ "$needed" = 0 ] && ok "the binary does not load a shared libarchive" \
    || bad "the binary does not load a shared libarchive ($needed NEEDED entries)"
else
  echo "SKIP: no readelf to read the binary's NEEDED entries"
fi
# What only the patched library can do. / 只有 patch 過的函式庫做得到的事。
mkdir -p "$TMP/t" && mkfifo "$TMP/t/pipe"
rc=0; "$ST" -c --zip -f "$TMP/a.zip" -C "$TMP" t > "$TMP/zip.out" 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "-c --zip stores a FIFO (patch 0002 is in the library)" \
  || bad "-c --zip stores a FIFO (rc $rc; $(tail -1 "$TMP/zip.out"))"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" = 0 ]
