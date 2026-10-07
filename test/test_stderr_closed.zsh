#!/usr/bin/env zsh
# test_stderr_closed.zsh -- an error reported while stderr cannot be written must not abort.
# test_stderr_closed.zsh -- stderr 無法寫入時回報錯誤，不得 abort。
#
#   ./test/test_stderr_closed.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_stderr_closed.zsh    # a specific binary
#
# FileHandle.write(_:) raises an Objective-C exception when the write fails, which Swift
# cannot catch, so with stderr closed (`2>&-`) or on a full volume the process ended with
# SIGABRT (rc=134) and the message it was giving was lost. Found 2026-10-07 when a RAM disk
# filled during a benchmark. swift_tar's own writes now use write(contentsOf:); the eprint
# of the full build comes from the lzfse2 submodule and was fixed there in 3a7e782.
#
# FileHandle.write(_:) 寫入失敗時拋出 Swift 攔不住的 Objective-C 例外，所以 stderr 關閉
# （`2>&-`）或位於滿的卷宗時，行程以 SIGABRT（rc=134）結束，原本要印的訊息也遺失。2026-10-07
# 量測時 RAM disk 寫滿而發現。swift_tar 自己的寫入已改用 write(contentsOf:)；完整版的 eprint
# 來自 lzfse2 submodule，已於其 3a7e782 修正。
set -euo pipefail

script_path="${0:A}"
HERE="${script_path:h}"
ROOT="${HERE:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[ -x "$ST" ] || { echo "error: build first — missing $ST" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# The status is the assertion, so it is captured rather than left to set -e.
# 斷言的是狀態本身，所以把它存下來，而不是交給 set -e。
rc=0; "$ST" -c --zstd --zstd-level abc -f /dev/null /dev/null 2>&- || rc=$?
if [ "$rc" -eq 1 ]; then ok "--zstd-level error with stderr closed exits 1"
else bad "--zstd-level error with stderr closed exits 1 (got $rc)"; fi

# The full build's eprint, from the lzfse2 submodule; counted since the pin moved to a
# commit carrying lzfse2 3a7e782.
# 完整版的 eprint，來自 lzfse2 submodule；pin 移到包含 lzfse2 3a7e782 的 commit 後正式計入。
rc=0; "$ST" -x -f /nonexistent-swift-tar-test.tar 2>&- || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ]; then ok "eprint error with stderr closed exits $rc, not a signal"
else bad "eprint error with stderr closed exits $rc, not a signal"; fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
