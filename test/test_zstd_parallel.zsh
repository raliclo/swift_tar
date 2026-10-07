#!/usr/bin/env zsh
# test_zstd_parallel.zsh -- --zstd-parallel must decode exactly what --zstd decodes.
# test_zstd_parallel.zsh -- --zstd-parallel 解出的內容必須與 --zstd 完全相同。
#
#   ./test/test_zstd_parallel.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_zstd_parallel.zsh    # a specific binary
#   ./test/test_zstd_parallel.zsh --help
#
# --zstd-parallel (2026-10-07) cuts complete frames out of the input and decodes them on
# several cores, falling back to the stream decoder when it cannot. Every check compares it
# with the stream decoder (--zstd) or with the original bytes, never with a fixed size, so a
# check cannot pass by both sides being wrong the same way and the reference being absent.
# The stream decoder is the reference because it is what every earlier release used.
#
# --zstd-parallel（2026-10-07）從輸入切出完整的 frame 以多核心解碼，切不出時退回串流解碼器。
# 每一項都拿它與串流解碼器（--zstd）或原始位元組比較，從不與固定大小比較。串流解碼器之所以是
# 基準，是因為先前每一版都用它。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,16p' "$script_path" | sed 's/^# \{0,1\}//'
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
same_bytes() {  # <desc> <file A> <file B>
  if [ -f "$2" ] && [ -f "$3" ] && cmp -s "$2" "$3"; then ok "$1"; else bad "$1"; fi
}

# A hang is a failure mode here -- a decoder that waits for a frame that never comes -- and a
# test that hangs with it reports nothing. Same helper and reasoning as test_blind_findings.
# 卡死在這裡是一種失敗形態——解碼器等一個永遠不會來的 frame——而與它一起卡死的測試什麼也
# 回報不了。輔助函式與理由同 test_blind_findings。
bounded() {  # <seconds> <command...>
  local seconds="$1"; shift
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@" || rc=$?
    return $rc
  fi
  "$@" &
  local pid=$!
  ( sleep "$seconds"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid" || rc=$?
  kill "$watcher" 2>/dev/null || true
  return $rc
}
# 124 is timeout(1)'s code, 137 a SIGKILL from the fallback watchdog.
# 124 是 timeout(1) 的代碼，137 是後備看門狗送出 SIGKILL 的結果。
not_hung() { [ "$1" -ne 124 ] && [ "$1" -ne 137 ]; }

cat_with() {  # <flag> <archive> <out> ; returns the decoder's status
  local rc=0
  bounded 120 "$ST" --cat "$1" -f "$2" > "$3" 2>/dev/null || rc=$?
  return $rc
}
# Decoder commands below end in `|| true` wherever the assertion is on the bytes they produce
# rather than on their status: under `set -e` a failing decoder would otherwise end the suite
# before the check that reports it. Where the status itself is asserted, it is captured.
# 以下的解碼指令，凡斷言看的是產出的位元組而非狀態者，都以 `|| true` 結尾：在 `set -e` 之下，
# 失敗的解碼器否則會在回報它的檢查之前就結束整個套件。要斷言狀態本身時，則把它存下來。

# ---- 1. swift_tar's own archives: many frames, one per 4 MiB chunk ----
# ---- 1. swift_tar 自己的封存：多個 frame，每 4 MiB 一個 ----
SRC="$TMP/src"; mkdir -p "$SRC/sub"
for i in 1 2 3 4 5; do head -c 3000000 /dev/urandom > "$SRC/r$i.bin"; done
# `|| true`: head closes the pipe once it has enough, yes then dies of SIGPIPE, and under
# pipefail that is the pipeline's status. The file is complete either way.
# `|| true`：head 讀夠就關閉管線，yes 隨即因 SIGPIPE 結束，在 pipefail 之下那就是整條管線的
# 狀態。檔案無論如何都是完整的。
yes 'a compressible line of text for zstd' | head -c 9000000 > "$SRC/text.txt" || true
print -r -- small > "$SRC/sub/small.txt"
( cd "$TMP" && "$ST" -c --zstd -f own.tar.zst src ) >/dev/null 2>&1
( cd "$TMP" && "$ST" -c -f own.tar src ) >/dev/null 2>&1

cat_with --zstd          "$TMP/own.tar.zst" "$TMP/own.stream.tar" || true
cat_with --zstd-parallel "$TMP/own.tar.zst" "$TMP/own.par.tar"    || true
same_bytes "own archive: --cat is byte-identical to the stream decoder" "$TMP/own.stream.tar" "$TMP/own.par.tar"
same_bytes "own archive: --cat reproduces the uncompressed tar" "$TMP/own.tar" "$TMP/own.par.tar"

mkdir -p "$TMP/x.stream" "$TMP/x.par"
"$ST" -x --zstd          -f "$TMP/own.tar.zst" -C "$TMP/x.stream" >/dev/null 2>&1 || true
"$ST" -x --zstd-parallel -f "$TMP/own.tar.zst" -C "$TMP/x.par"    >/dev/null 2>&1 || true
if diff -r "$TMP/x.stream" "$TMP/x.par" >/dev/null 2>&1 && [ -f "$TMP/x.par/src/text.txt" ]; then
  ok "own archive: -x extracts the same tree"
else
  bad "own archive: -x extracts the same tree"
fi
eq "own archive: -t lists the same members" \
   "$("$ST" -t --zstd -f "$TMP/own.tar.zst" 2>/dev/null | sort | tr '\n' ' ')" \
   "$("$ST" -t --zstd-parallel -f "$TMP/own.tar.zst" 2>/dev/null | sort | tr '\n' ' ')"

# Standard input: multiscp streams with `-f -`, which cannot seek. / 標準輸入：multiscp 以
# `-f -` 串流，無法 seek。
"$ST" --cat --zstd-parallel -f - < "$TMP/own.tar.zst" > "$TMP/own.pipe.tar" 2>/dev/null || true
same_bytes "own archive: reading from standard input gives the same bytes" "$TMP/own.tar" "$TMP/own.pipe.tar"

"$ST" --cat --zstd-parallel -n 1 -f "$TMP/own.tar.zst" > "$TMP/own.n1.tar" 2>/dev/null || true
same_bytes "own archive: -n 1 (one frame at a time) gives the same bytes" "$TMP/own.tar" "$TMP/own.n1.tar"

# On creation --zstd-parallel is --zstd: the same archive, byte for byte.
# 建立時 --zstd-parallel 就是 --zstd：逐位元組相同的封存。
( cd "$TMP" && "$ST" -c --zstd-parallel -f own.par.tar.zst src ) >/dev/null 2>&1
same_bytes "create: --zstd-parallel writes the same archive as --zstd" "$TMP/own.tar.zst" "$TMP/own.par.tar.zst"

# ---- 2. archives the zstd CLI wrote ----
# ---- 2. zstd CLI 寫出的封存 ----
if command -v zstd >/dev/null 2>&1; then
  # One frame for the whole tar: nothing to split until the frame is complete.
  # 整個 tar 一個 frame：frame 完整之前沒有東西可切。
  zstd -q -c "$TMP/own.tar" > "$TMP/cli.one.zst"
  cat_with --zstd-parallel "$TMP/cli.one.zst" "$TMP/cli.one.out" || true
  same_bytes "zstd CLI, single frame: decodes to the original tar" "$TMP/own.tar" "$TMP/cli.one.out"

  # Two frames back to back, each with its content size. / 兩個背靠背的 frame，各帶 content size。
  half=$(( $(wc -c < "$TMP/own.tar") / 2 ))
  head -c "$half" "$TMP/own.tar" > "$TMP/part1"
  tail -c +"$(( half + 1 ))" "$TMP/own.tar" > "$TMP/part2"
  { zstd -q -c "$TMP/part1"; zstd -q -c "$TMP/part2"; } > "$TMP/cli.two.zst"
  cat_with --zstd-parallel "$TMP/cli.two.zst" "$TMP/cli.two.out" || true
  same_bytes "zstd CLI, two concatenated frames: decodes to the original tar" "$TMP/own.tar" "$TMP/cli.two.out"

  # No content size in the header: the worker cannot decode in one call and streams the frame.
  # 標頭沒有 content size：工作執行緒無法一次解完，改以串流解這個 frame。
  zstd -q --no-content-size -c "$TMP/own.tar" > "$TMP/cli.nosize.zst"
  cat_with --zstd-parallel "$TMP/cli.nosize.zst" "$TMP/cli.nosize.out" || true
  same_bytes "zstd CLI, no content size: decodes to the original tar" "$TMP/own.tar" "$TMP/cli.nosize.out"

  # One frame that compresses to more than the 64 MiB the splitter will hold: it gives up
  # splitting and hands the rest to the stream decoder.
  # 壓縮後超過切分器願意持有的 64 MiB 的單一 frame：放棄切分，其餘交給串流解碼器。
  mkdir -p "$TMP/big"
  head -c 70000000 /dev/urandom > "$TMP/big/random.bin"
  ( cd "$TMP" && "$ST" -c -f big.tar big ) >/dev/null 2>&1
  zstd -q -1 -c "$TMP/big.tar" > "$TMP/cli.big.zst"
  rc=0; cat_with --zstd-parallel "$TMP/cli.big.zst" "$TMP/cli.big.out" || rc=$?
  eq "zstd CLI, one frame over 64 MiB compressed: decoder succeeds" "0" "$rc"
  same_bytes "zstd CLI, one frame over 64 MiB compressed: decodes to the original tar" "$TMP/big.tar" "$TMP/cli.big.out"
else
  echo "SKIP: zstd CLI archives (no zstd command here)"
fi

# A skippable frame (magic 0x184D2A50, 4-byte length, payload) after the data frames. It
# decodes to nothing and must not end the run. / data frame 之後接一個 skippable frame（magic
# 0x184D2A50、4 位元組長度、內容）。它解出來是空的，不能讓執行結束。
cp "$TMP/own.tar.zst" "$TMP/skip.zst"
printf '\x50\x2a\x4d\x18\x04\x00\x00\x00abcd' >> "$TMP/skip.zst"
cat_with --zstd          "$TMP/skip.zst" "$TMP/skip.stream" || true
cat_with --zstd-parallel "$TMP/skip.zst" "$TMP/skip.par"    || true
same_bytes "a trailing skippable frame: same bytes as the stream decoder" "$TMP/skip.stream" "$TMP/skip.par"
same_bytes "a trailing skippable frame: decodes to the original tar" "$TMP/own.tar" "$TMP/skip.par"

# ---- 3. damaged input: fail, do not hang, write only a correct prefix ----
# ---- 3. 損壞的輸入：要失敗、不能卡住、只寫出正確的前綴 ----
size=$(wc -c < "$TMP/own.tar.zst" | tr -d ' ')
head -c "$(( size - 1000 ))" "$TMP/own.tar.zst" > "$TMP/trunc.zst"
rc_s=0; cat_with --zstd          "$TMP/trunc.zst" "$TMP/trunc.stream" || rc_s=$?
rc_p=0; cat_with --zstd-parallel "$TMP/trunc.zst" "$TMP/trunc.par"    || rc_p=$?
eq "truncated input: the stream decoder fails (reference)" "yes" "$( [ $rc_s -ne 0 ] && echo yes || echo no )"
eq "truncated input: --zstd-parallel fails too" "yes" "$( [ $rc_p -ne 0 ] && echo yes || echo no )"
eq "truncated input: --zstd-parallel does not hang" "yes" "$( not_hung $rc_p && echo yes || echo "no (rc=$rc_p)" )"
# A prefix test by taking that many bytes of the correct output, not `cmp -n`: on macOS
# `cmp -n N` reports "EOF" and exits 1 when one file is exactly N bytes long, so an earlier
# version failed this for both decoders while both outputs were correct prefixes.
# 以「取正確輸出的同樣長度」做前綴檢查，而非 `cmp -n`：macOS 上當其中一個檔案正好 N 位元組時，
# `cmp -n N` 會回報「EOF」並以 1 結束，所以較早的版本讓兩種解碼器都在這裡失敗，而兩者的輸出
# 其實都是正確的前綴。
is_prefix_of() {  # <candidate> <full>
  local n; n=$(wc -c < "$1" | tr -d ' ')
  head -c "$n" "$2" | cmp -s - "$1"
}
if is_prefix_of "$TMP/trunc.par" "$TMP/own.tar"; then
  ok "truncated input: what was written is a prefix of the correct output"
else
  bad "truncated input: what was written is a prefix of the correct output"
fi
same_bytes "truncated input: writes exactly what the stream decoder writes" "$TMP/trunc.stream" "$TMP/trunc.par"

# Damage zstd can detect: two valid archives with bytes between them that are not a frame.
# The stream decoder writes the first archive and fails on the gap; so must this.
# zstd 偵測得到的損毀：兩個有效封存之間夾著不成 frame 的位元組。串流解碼器寫出第一個封存
# 後在空隙處失敗；這裡也必須如此。
{ cat "$TMP/own.tar.zst"; printf 'not a zstd frame'; cat "$TMP/own.tar.zst"; } > "$TMP/gap.zst"
rc_s=0; cat_with --zstd          "$TMP/gap.zst" "$TMP/gap.stream" || rc_s=$?
rc_p=0; cat_with --zstd-parallel "$TMP/gap.zst" "$TMP/gap.par"    || rc_p=$?
eq "bytes between frames: the stream decoder fails (reference)" "yes" "$( [ $rc_s -ne 0 ] && echo yes || echo no )"
eq "bytes between frames: --zstd-parallel fails too" "yes" "$( [ $rc_p -ne 0 ] && echo yes || echo no )"
eq "bytes between frames: --zstd-parallel does not hang" "yes" "$( not_hung $rc_p && echo yes || echo "no (rc=$rc_p)" )"
same_bytes "bytes between frames: nothing past the bad bytes is written" "$TMP/own.tar" "$TMP/gap.par"

# 64 bytes overwritten inside a frame. Frames carry a content checksum by default since
# 2026-10-07, so both decoders must fail. They do not stop at the same byte: the stream
# decoder has already written the damaged frame's bytes when the checksum at its end fails,
# while the parallel decoder writes a frame only once it has decoded and verified the whole
# of it. What it writes is therefore a prefix of the correct output.
# 在 frame 內覆寫 64 位元組。自 2026-10-07 起 frame 預設帶內容校驗碼，所以兩個解碼器都必須
# 失敗。兩者停下的位置不同：串流解碼器在 frame 結尾的校驗失敗時，已寫出了受損 frame 的位元組；
# 平行解碼器則要整個 frame 解完並驗證後才寫出。因此它寫出的是正確輸出的前綴。
cp "$TMP/own.tar.zst" "$TMP/corrupt.zst"
head -c 64 /dev/urandom | dd of="$TMP/corrupt.zst" bs=1 seek="$(( size / 2 ))" conv=notrunc 2>/dev/null
rc_s=0; cat_with --zstd          "$TMP/corrupt.zst" "$TMP/corrupt.stream" || rc_s=$?
rc_p=0; cat_with --zstd-parallel "$TMP/corrupt.zst" "$TMP/corrupt.par"    || rc_p=$?
eq "corrupt inside a frame: the stream decoder fails (reference)" "yes" "$( [ $rc_s -ne 0 ] && echo yes || echo no )"
eq "corrupt inside a frame: --zstd-parallel fails too" "yes" "$( [ $rc_p -ne 0 ] && echo yes || echo no )"
if [ -f "$TMP/corrupt.par" ] && is_prefix_of "$TMP/corrupt.par" "$TMP/own.tar"; then
  ok "corrupt inside a frame: what was written is a prefix of the correct output"
else
  bad "corrupt inside a frame: what was written is a prefix of the correct output"
fi

# The same damage in an archive written with --no-checksum is invisible to zstd: random data
# stored raw decodes "successfully" to different bytes, and the stream decoder exits 0
# (measured 2026-10-07). There the property is agreement with the stream decoder.
# 同樣的損毀若發生在以 --no-checksum 寫出的封存中，zstd 看不見：以原始區塊儲存的隨機資料會
# 「成功」解成不同的位元組，串流解碼器以 0 結束（2026-10-07 實測）。此時要求的性質是與串流
# 解碼器一致。
( cd "$TMP" && "$ST" -c --zstd --no-checksum -f nock.tar.zst src ) >/dev/null 2>&1
nsize=$(wc -c < "$TMP/nock.tar.zst" | tr -d ' ')
cp "$TMP/nock.tar.zst" "$TMP/corrupt-nock.zst"
head -c 64 /dev/urandom | dd of="$TMP/corrupt-nock.zst" bs=1 seek="$(( nsize / 2 ))" conv=notrunc 2>/dev/null
rc_s=0; cat_with --zstd          "$TMP/corrupt-nock.zst" "$TMP/corrupt-nock.stream" || rc_s=$?
rc_p=0; cat_with --zstd-parallel "$TMP/corrupt-nock.zst" "$TMP/corrupt-nock.par"    || rc_p=$?
eq "corrupt, --no-checksum: same status as the stream decoder" "$rc_s" "$rc_p"
same_bytes "corrupt, --no-checksum: same bytes as the stream decoder" "$TMP/corrupt-nock.stream" "$TMP/corrupt-nock.par"

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
