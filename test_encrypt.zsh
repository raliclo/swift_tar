#!/usr/bin/env zsh
# test_encrypt.zsh
# Verify swift_tar's encryption layer: ChaCha20-Poly1305 over 4 MiB chunks,
# wrapped OUTSIDE the compression codec. Covers the RFC test vectors, keyfile
# and passphrase key paths, layering with each codec, and — most importantly —
# that a wrong key, tampering, reordering and truncation are all rejected.
# 驗證 swift_tar 加密層：以 ChaCha20-Poly1305 對 4 MiB 分塊加密，包在壓縮 codec
# 之外。涵蓋 RFC 測試向量、keyfile 與密語兩種金鑰路徑、與各 codec 的疊層，以及
# 最重要的——錯誤金鑰、竄改、重排與截斷皆須被拒絕。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UNAME_S="$(uname -s)"
if [ -z "${ST:-}" ]; then
  case "$UNAME_S" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
  esac
fi
if [ -z "${SKIP_SLOW_XZ+x}" ]; then
  case "$UNAME_S" in
    MSYS*|MINGW*|CYGWIN*) SKIP_SLOW_XZ=1 ;;
    *) SKIP_SLOW_XZ=0 ;;
  esac
fi

if [ ! -x "$ST" ]; then
  echo "error: build first — missing $ST" >&2
  exit 1
fi

LOG="$HERE/test_encrypt.log"
exec > >(tee "$LOG") 2>&1

TMP="$(mktemp -d "$HERE/.test_encrypt.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
echo "[Info] swift_tar: $ST"
echo "[Info] skip slow xz: $SKIP_SLOW_XZ"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
# must_fail: the command has to exit non-zero / must_fail：該指令必須以非零結束
must_fail() { local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc (unexpectedly succeeded)"; else ok "$desc"; fi
}
run_with_timeout() { local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  ( sleep "$seconds"; kill "$pid" >/dev/null 2>&1 || true ) &
  local watchdog=$!
  wait "$pid"
  local rc=$?
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}
must_fail_fast() { local desc="$1"; shift
  if run_with_timeout 15 "$@" >/dev/null 2>&1; then bad "$desc (unexpectedly succeeded)"; else ok "$desc"; fi
}

SRC="$TMP/src"; mkdir -p "$SRC"
printf 'alpha\n' > "$SRC/a.txt"
printf 'bravo\n' > "$SRC/b.txt"
# >4 MiB so the chunked AEAD path and a partial final chunk are both exercised.
# Real image content when the sampled corpus is present: one 1080p RGB1 payload
# is 6,220,800 B, which crosses the 4 MiB chunk boundary and leaves a partial
# tail, exactly what this needs. The corpus is 285 MB and not in the repository,
# so a labelled random fallback keeps the AEAD path covered on a fresh clone --
# coverage of the chunking must not depend on a volume being mounted.
# 超過 4 MiB，同時涵蓋分塊 AEAD 路徑與不足一塊的尾段。取樣語料存在時使用真實影像內容：
# 一張 1080p 的 RGB1 payload 為 6,220,800 B，跨過 4 MiB 分塊邊界並留下不足一塊的尾段，
# 正是此處所需。該語料 285 MB 且不入版，故在乾淨 clone 上以「明確標示的隨機資料」備援，
# 使分塊路徑的覆蓋率不依賴某個磁碟區是否掛載。
BLOB_SRC=""
# (N) is the zsh null-glob qualifier: an unmatched pattern expands to nothing
# instead of aborting the script. Under bash the bare glob was left as a literal
# and the `[ -f ]` below rejected it, but zsh's default NOMATCH errors out first,
# so the corpus-absent fallback would never be reached on macOS or Linux. This
# machine hides it -- the scoop zsh's .zshenv does `unsetopt nomatch`.
# (N) 為 zsh 的 null-glob qualifier：未匹配時展開為空，而非中止腳本。在 bash 下
# 未匹配的 glob 會原樣保留為字面值、由下方 `[ -f ]` 擋掉；但 zsh 預設的 NOMATCH
# 會搶先報錯，導致 macOS/Linux 上根本走不到「語料不存在」的 fallback。本機看不出
# 問題——scoop zsh 的 .zshenv 設了 `unsetopt nomatch`。
for f in "$HERE"/verifications/rgb1/sample_consecutive/*.rgb1(N); do
  [ -f "$f" ] || continue
  tail -c +877 "$f" > "$SRC/blob.bin"
  BLOB_SRC="sampled video frame ${f##*/}"
  break
done
if [ -z "$BLOB_SRC" ]; then
  head -c 5000000 /dev/urandom > "$SRC/blob.bin"
  BLOB_SRC="random (no sampled corpus; run verifications/rgb1/make_consecutive_corpus.zsh)"
fi
echo "[Info] blob: $BLOB_SRC ($(wc -c < "$SRC/blob.bin" | tr -d ' ') B)"
KEY="$TMP/key"; head -c 64 /dev/urandom > "$KEY"
WRONG="$TMP/wrongkey"; head -c 64 /dev/urandom > "$WRONG"

# ---------------------------------------------------------------------------
# 1) The primitives themselves, against the published vectors.
#    原語本身，對照公開測試向量。
# ---------------------------------------------------------------------------
# Unit tests live in cryptoSelfTest() so they can call the primitives directly
# (vectors from RFC 8439/4231/7914 and FIPS 180-4, plus header and chunk-framing
# cases). Each one is surfaced here rather than collapsed into a single result.
# 單元測試位於 cryptoSelfTest()，可直接呼叫原語（向量取自 RFC 8439/4231/7914 與
# FIPS 180-4，另含標頭與 chunk 切分案例）。此處逐案呈現，不壓縮成單一結果。
echo "--- unit tests (crypto primitives, header parsing, chunk framing) ---"
if "$ST" --crypto-selftest > "$TMP/selftest.out" 2>&1; then
  while IFS= read -r line; do
    case "$line" in
      PASS:*) ok "unit ${line#PASS: }" ;;
    esac
  done < "$TMP/selftest.out"
else
  bad "crypto unit tests failed"; cat "$TMP/selftest.out"
fi
echo "--- integration tests (CLI end-to-end) ---"

# ---------------------------------------------------------------------------
# 2) Keyfile round-trip for plain tar, and the container is really encrypted.
#    keyfile 純 tar 往返，且容器確實已加密。
# ---------------------------------------------------------------------------
"$ST" -c --keyfile "$KEY" -f "$TMP/plain.enc" -C "$TMP" src
[ "$(head -c 8 "$TMP/plain.enc")" = "SWTARC01" ] \
  && ok "container carries the encryption magic" \
  || bad "container magic missing"

# the plaintext must not be recoverable from the raw bytes / 原始位元組不得洩漏明文
if grep -qa "alpha" "$TMP/plain.enc"; then bad "plaintext leaks into the archive"
else ok "plaintext does not appear in the encrypted archive"; fi

# a plain tar reader must not be able to read it / 純 tar 讀取器不得能解讀
must_fail "system tar cannot read the encrypted archive" tar -tf "$TMP/plain.enc"

mkdir -p "$TMP/out_plain"
"$ST" -x --keyfile "$KEY" -f "$TMP/plain.enc" -C "$TMP/out_plain"
diff -r "$SRC" "$TMP/out_plain/src" >/dev/null \
  && ok "keyfile: plain tar round-trip" || bad "keyfile: plain tar round-trip"

# the keyfile path must not be archived as a member / keyfile 路徑不得被當成成員打包
"$ST" -t --keyfile "$KEY" -f "$TMP/plain.enc" > "$TMP/list.txt"
grep -q "key" "$TMP/list.txt" && bad "keyfile path leaked into the entry list" \
                              || ok "keyfile path is not treated as an input file"

# ---------------------------------------------------------------------------
# 3) Encryption layers over every codec, and --identify reports the chain.
#    加密可疊在各 codec 之上，且 --identify 會回報整條鏈。
# ---------------------------------------------------------------------------
layer() { # label codec-flag expected-chain-fragment
  local label="$1" flag="$2" want="$3" arc="$TMP/l_$1.enc" out="$TMP/lo_$1"
  if [ -n "$flag" ]; then
    "$ST" -c "$flag" --keyfile "$KEY" -f "$arc" -C "$TMP" src
  else
    "$ST" -c --keyfile "$KEY" -f "$arc" -C "$TMP" src
  fi
  local chain; chain="$("$ST" --identify --keyfile "$KEY" -f "$arc" | sed 's/^.*: //')"
  mkdir -p "$out"; "$ST" -x --keyfile "$KEY" -f "$arc" -C "$out"
  if diff -r "$SRC" "$out/src" >/dev/null 2>&1 && [ "$chain" = "$want" ]; then
    ok "layered $label: round-trip + identify reports \"$chain\""
  else
    bad "layered $label (chain=[$chain] want=[$want])"
  fi
}
layer plain ""       "encrypted (ChaCha20-Poly1305) → tar"
layer gzip  "--gzip" "encrypted (ChaCha20-Poly1305) → gzip → tar"
layer zstd  "--zstd" "encrypted (ChaCha20-Poly1305) → zstd → tar"
if [ "${SKIP_SLOW_XZ:-0}" = "1" ]; then
  echo "SKIP: layered xz (known slow on Windows / Windows 已知較慢)"
else
  layer xz "--xz" "encrypted (ChaCha20-Poly1305) → xz → tar"
fi

# ---------------------------------------------------------------------------
# 3b) --encrypt-only / --decrypt-only: the encryption layer on its own. The
#     decrypted result must still be the compressed archive, not raw tar.
#     --encrypt-only／--decrypt-only：單獨作用的加密層。解密結果必須仍是壓縮後
#     的封存，而非原始 tar。
# ---------------------------------------------------------------------------
# The point of this block is a .tgz swift_tar did NOT make, so the encryption
# layer is shown to work on a foreign archive. Two ways that goes wrong if the
# tool is chosen by name:
#
#   busybox tar cannot compress at all. On the buildroot Linux VM `tar` is the
#   busybox applet and `-z` is rejected outright -- intended there, since that
#   rootfs deliberately omits GNU tar (BR2_PACKAGE_TAR unset) and ships bsdtar
#   for the compressed cases.
#
#   `tar` on that same VM is swift_tar, installed under that name. Using it here
#   would encrypt swift_tar's own output and call it foreign, which is not a
#   test of anything.
#
# So probe by what each candidate says it is, and skip the block cleanly if no
# compressing third-party tar exists rather than failing on a precondition the
# platform was never expected to meet.
# 本段的重點是取得一個「並非由 swift_tar 產生」的 .tgz，藉以證明加密層對外來封存
# 同樣成立。若以名稱挑選工具，有兩種出錯方式：
#
#   busybox tar 根本不能壓縮。在 buildroot 的 Linux VM 上，`tar` 即為 busybox
#   applet，`-z` 會被直接拒絕——那是該平台的預期行為，因為該 rootfs 刻意不含
#   GNU tar（未設 BR2_PACKAGE_TAR），並以 bsdtar 承擔需要壓縮的情況。
#
#   同一台 VM 上的 `tar` 就是 swift_tar，以該名稱安裝。在此使用它，等於把 swift_tar
#   自己的輸出加密後稱之為外來封存，那什麼也證明不了。
#
# 故依各候選者的自我描述探測，若不存在可壓縮的第三方 tar 則乾淨跳過本段，而不是在
# 一個該平台本就不預期滿足的前提上失敗。
FOREIGN_TAR=""
for cand in tar bsdtar gtar /usr/bin/bsdtar /c/Windows/System32/tar.exe; do
  command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
  ver=$("$cand" --version 2>&1 | head -1)
  case "$ver" in
    *swift_tar*) continue ;;                 # ourselves / 我們自己
    *bsdtar*|*"GNU tar"*) ;;                 # can compress / 能壓縮
    *) continue ;;                           # busybox and anything unknown
  esac
  if "$cand" -czf "$TMP/outside.tgz" -C "$TMP" src 2>/dev/null; then
    FOREIGN_TAR="$cand"; break
  fi
done

if [ -z "$FOREIGN_TAR" ]; then
  echo "SKIP: no third-party tar here can write a .tgz — --encrypt-only/--decrypt-only on a foreign archive not exercised"
  echo "跳過：此處沒有能寫出 .tgz 的第三方 tar，未驗證加密層對外來封存的作用"
else
"$ST" --encrypt-only --keyfile "$KEY" -f "$TMP/outside.tgz" > "$TMP/outside.tgz.enc"
[ "$(head -c 8 "$TMP/outside.tgz.enc")" = "SWTARC01" ] \
  && ok "--encrypt-only: output carries the encryption magic" \
  || bad "--encrypt-only: magic missing"

"$ST" --decrypt-only --keyfile "$KEY" -f "$TMP/outside.tgz.enc" > "$TMP/outside.back.tgz"
cmp -s "$TMP/outside.tgz" "$TMP/outside.back.tgz" \
  && ok "--encrypt-only → --decrypt-only round-trips byte-for-byte" \
  || bad "--encrypt-only → --decrypt-only differs"

# the decrypted payload must still be valid gzip that other tools can read
# 解密後的內容必須仍是其他工具可讀的合法 gzip
gzip -t "$TMP/outside.back.tgz" 2>/dev/null \
  && ok "--decrypt-only leaves a valid gzip stream (compression preserved)" \
  || bad "--decrypt-only output is not valid gzip"
"$FOREIGN_TAR" -tzf "$TMP/outside.back.tgz" >/dev/null 2>&1 \
  && ok "--decrypt-only output is readable by $FOREIGN_TAR" \
  || bad "--decrypt-only output not readable by $FOREIGN_TAR"

# --decrypt-only on a swift_tar-encrypted .tar.gz must return gzip, while --cat
# on the same file returns the uncompressed tar / 同一檔案上 --decrypt-only 回傳
# gzip，--cat 則回傳未壓縮 tar
"$ST" -c --gzip --keyfile "$KEY" -f "$TMP/enc.tgz.enc" -C "$TMP" src
"$ST" --decrypt-only --keyfile "$KEY" -f "$TMP/enc.tgz.enc" > "$TMP/d_only.out"
"$ST" --cat         --keyfile "$KEY" -f "$TMP/enc.tgz.enc" > "$TMP/cat.out"
if [ "$(head -c 2 "$TMP/d_only.out" | od -An -tx1 | tr -d ' ')" = "1f8b" ] \
   && tar -tf "$TMP/cat.out" >/dev/null 2>&1; then
  ok "--decrypt-only keeps compression while --cat undoes it"
else
  bad "--decrypt-only/--cat do not differ as documented"
fi

must_fail "--decrypt-only on a non-encrypted file is rejected" \
  "$ST" --decrypt-only --keyfile "$KEY" -f "$TMP/outside.tgz"
must_fail "--decrypt-only with the wrong key is rejected" \
  "$ST" --decrypt-only --keyfile "$WRONG" -f "$TMP/outside.tgz.enc"
fi   # FOREIGN_TAR

# ---------------------------------------------------------------------------
# 4) Attacks: every one of these must be rejected, not silently accepted.
#    攻擊情境：以下每一項都必須被拒絕，不得靜默接受。
# ---------------------------------------------------------------------------
must_fail "wrong keyfile is rejected" "$ST" -t --keyfile "$WRONG" -f "$TMP/plain.enc"

corrupt() { # dest offset
  cp "$TMP/plain.enc" "$2"
  python3 - "$2" "$3" <<'PY'
import sys
path, off = sys.argv[1], int(sys.argv[2])
d = bytearray(open(path, 'rb').read())
d[off] ^= 0x01
open(path, 'wb').write(d)
PY
}
corrupt _ "$TMP/t_cipher.enc" 60      # inside the first chunk's ciphertext
must_fail "flipped ciphertext bit is rejected" "$ST" -t --keyfile "$KEY" -f "$TMP/t_cipher.enc"
corrupt _ "$TMP/t_salt.enc" 20        # inside the header salt
must_fail "tampered header salt is rejected" "$ST" -t --keyfile "$KEY" -f "$TMP/t_salt.enc"
corrupt _ "$TMP/t_kdf.enc" 10         # header scrypt logN
must_fail "tampered KDF parameters are rejected" "$ST" -t --keyfile "$KEY" -f "$TMP/t_kdf.enc"

# truncation: drop the authenticated final marker / 截斷：移除已驗證的結尾標記
head -c $(( $(wc -c < "$TMP/plain.enc") - 40 )) "$TMP/plain.enc" > "$TMP/t_trunc.enc"
must_fail "truncated archive is rejected" "$ST" -t --keyfile "$KEY" -f "$TMP/t_trunc.enc"

# a non-encrypted archive must still read normally / 未加密封存仍須正常讀取
"$ST" -c -f "$TMP/clear.tar" -C "$TMP" src
"$ST" -t -f "$TMP/clear.tar" >/dev/null && ok "unencrypted archives are unaffected" \
                                        || bad "unencrypted archives broke"

# an empty keyfile is a usage error, not a silent weak key / 空 keyfile 應報錯
: > "$TMP/empty.key"
must_fail "empty keyfile is rejected" "$ST" -c --keyfile "$TMP/empty.key" -f "$TMP/x.enc" -C "$TMP" src

# ---------------------------------------------------------------------------
# 5) Non-interactive stdin must not silently produce an unencrypted archive.
#    非互動 stdin 不得靜默產生未加密封存。
# ---------------------------------------------------------------------------
must_fail_fast "--encrypt without a TTY and without --keyfile fails" \
  sh -c "\"$ST\" -c --encrypt -f \"$TMP/noatty.enc\" -C \"$TMP\" src < /dev/null"
[ ! -s "$TMP/noatty.enc" ] && ok "no archive is left behind when the key cannot be obtained" \
                           || bad "an archive was written without a key"

# ---------------------------------------------------------------------------
echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
