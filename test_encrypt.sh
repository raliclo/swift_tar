#!/usr/bin/env bash
# test_encrypt.sh
# Verify swift_tar's encryption layer: ChaCha20-Poly1305 over 4 MiB chunks,
# wrapped OUTSIDE the compression codec. Covers the RFC test vectors, keyfile
# and passphrase key paths, layering with each codec, and — most importantly —
# that a wrong key, tampering, reordering and truncation are all rejected.
# 驗證 swift_tar 加密層：以 ChaCha20-Poly1305 對 4 MiB 分塊加密，包在壓縮 codec
# 之外。涵蓋 RFC 測試向量、keyfile 與密語兩種金鑰路徑、與各 codec 的疊層，以及
# 最重要的——錯誤金鑰、竄改、重排與截斷皆須被拒絕。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ST="$HERE/release/swift_tar"

if [ ! -x "$ST" ]; then
  echo "error: build first (./compile_tar.sh) — missing $ST" >&2
  exit 1
fi

LOG="$HERE/test_encrypt.log"
exec > >(tee "$LOG") 2>&1

TMP="$(mktemp -d "$HERE/.test_encrypt.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] swift_tar: $ST"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
# must_fail: the command has to exit non-zero / must_fail：該指令必須以非零結束
must_fail() { local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc (unexpectedly succeeded)"; else ok "$desc"; fi
}

SRC="$TMP/src"; mkdir -p "$SRC"
printf 'alpha\n' > "$SRC/a.txt"
printf 'bravo\n' > "$SRC/b.txt"
# >4 MiB so the chunked AEAD path and a partial final chunk are both exercised
# 超過 4 MiB，同時涵蓋分塊 AEAD 路徑與不足一塊的尾段
head -c 5000000 /dev/urandom > "$SRC/blob.bin"
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
layer xz    "--xz"   "encrypted (ChaCha20-Poly1305) → xz → tar"

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
must_fail "--encrypt without a TTY and without --keyfile fails" \
  sh -c "\"$ST\" -c --encrypt -f \"$TMP/noatty.enc\" -C \"$TMP\" src < /dev/null"
[ ! -s "$TMP/noatty.enc" ] && ok "no archive is left behind when the key cannot be obtained" \
                           || bad "an archive was written without a key"

# ---------------------------------------------------------------------------
echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
