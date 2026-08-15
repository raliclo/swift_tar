#!/usr/bin/env bash
# encrypt_windows_correctness.sh -- Windows/MSYS correctness smoke test for
# swift_tar's ChaCha20-Poly1305 encryption layer.
#
# encrypt_windows_correctness.sh -- 在 Windows/MSYS 上快速驗證 swift_tar 的
# ChaCha20-Poly1305 加密層正確性。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-$ROOT_DIR/release/swift_tar.exe}"
OUTPUT_TXT="${OUTPUT_TXT:-$SCRIPT_DIR/encrypt_windows_correctness_output.txt}"

if [ ! -x "$SWIFT_TAR_BIN" ]; then
    echo "[Error] swift_tar.exe not found at $SWIFT_TAR_BIN" >&2
    echo "        Build first with compile_tar-win.bat." >&2
    exit 1
fi

run_test() {
    local tmp
    tmp="$(mktemp -d /tmp/swift_tar_win_crypto.XXXXXX)"
    cleanup() { rm -rf "$tmp"; }
    trap cleanup EXIT

    mkdir -p "$tmp/src"
    printf 'alpha\n' > "$tmp/src/a.txt"
    printf 'bravo\n' > "$tmp/src/b.txt"
    # Real image content when the sampled corpus is present; see test_encrypt.sh for
# the same pattern and the reason a labelled random fallback stays. One 1080p
# RGB1 payload is 6,220,800 B, which crosses the 4 MiB chunk boundary and leaves
# a partial tail.
# 取樣語料存在時使用真實影像內容；相同作法與保留「明確標示的隨機備援」之理由見
# test_encrypt.sh。一張 1080p 的 RGB1 payload 為 6,220,800 B，跨過 4 MiB 分塊邊界並
# 留下不足一塊的尾段。
_blob_src=""
for _f in "$SCRIPT_DIR"/rgb1/sample_consecutive/*.rgb1; do
  [ -f "$_f" ] || continue
  tail -c +877 "$_f" > "$tmp/src/blob.bin"
  _blob_src="sampled video frame ${_f##*/}"
  break
done
if [ -z "$_blob_src" ]; then
  head -c 5000000 /dev/urandom > "$tmp/src/blob.bin"
  _blob_src="random (no sampled corpus)"
fi
echo "[Info] blob: $_blob_src"
    head -c 64 /dev/urandom > "$tmp/key"
    head -c 64 /dev/urandom > "$tmp/wrong"

    local pass=0
    local fail=0
    ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
    bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
    must_fail() {
        local desc="$1"
        shift
        if "$@" >/dev/null 2>&1; then
            bad "$desc"
        else
            ok "$desc"
        fi
    }

    check_layer() {
        local label="$1"
        local flag="$2"
        local arc="$tmp/$label.enc"
        local out="$tmp/out_$label"

        if [ -n "$flag" ]; then
            "$SWIFT_TAR_BIN" -c "$flag" --keyfile "$tmp/key" -f "$arc" -C "$tmp" src
        else
            "$SWIFT_TAR_BIN" -c --keyfile "$tmp/key" -f "$arc" -C "$tmp" src
        fi

        mkdir -p "$out"
        "$SWIFT_TAR_BIN" -x --keyfile "$tmp/key" -f "$arc" -C "$out"
        if diff -r "$tmp/src" "$out/src" >/dev/null 2>&1; then
            ok "$label encrypted create/extract round-trip"
        else
            bad "$label encrypted create/extract round-trip"
        fi
    }

    # The OS build, not just the product version, identifies the environment:
    # macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
    # 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
    # CPU Power 0 mW，26A5406e 則否。
    echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
    echo "[Info] uname: $(uname -a)"
    local version_line
    version_line="$("$SWIFT_TAR_BIN" --version 2>&1 | tr -d '\r')"
    echo "[Info] swift_tar: $version_line"
    echo

    echo "== crypto self-test =="
    "$SWIFT_TAR_BIN" --crypto-selftest
    local selftest_rc=$?
    echo "[Info] crypto self-test rc: $selftest_rc"
    echo

    echo "== Windows CLI correctness subset =="
    check_layer plain ""
    check_layer gzip --gzip
    check_layer zstd --zstd

    tar -cf "$tmp/base.tar" -C "$tmp" src
    "$SWIFT_TAR_BIN" --encrypt-only --keyfile "$tmp/key" -f "$tmp/base.tar" > "$tmp/base.tar.enc"
    "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$tmp/key" -f "$tmp/base.tar.enc" > "$tmp/base.back.tar"
    cmp -s "$tmp/base.tar" "$tmp/base.back.tar" \
        && ok "encrypt-only/decrypt-only byte-for-byte" \
        || bad "encrypt-only/decrypt-only byte-for-byte"

    must_fail "wrong key is rejected" \
        "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$tmp/wrong" -f "$tmp/base.tar.enc"

    cp "$tmp/base.tar.enc" "$tmp/tamper.enc"
    printf 'X' | dd of="$tmp/tamper.enc" bs=1 seek=60 count=1 conv=notrunc >/dev/null 2>&1
    must_fail "tampered ciphertext is rejected" \
        "$SWIFT_TAR_BIN" --decrypt-only --keyfile "$tmp/key" -f "$tmp/tamper.enc"

    echo "SUMMARY: PASS=$pass FAIL=$fail"
    [ "$selftest_rc" -eq 0 ] && [ "$fail" -eq 0 ]
}

run_test | tee "$OUTPUT_TXT"
