#!/usr/bin/env zsh
# test_no_lzfse.sh
# Verify the public/distributable build (compile_no_lzfse.sh) ships NONE of the
# private LZFSE engine: no bvx3/other3 in the binary, LZFSE codecs unavailable,
# LZFSE archives undecodable — while standard codecs and plain tar still work.
# The full build (compile_tar.sh) is used as the contrast that DOES have LZFSE.
# 驗證公開版（compile_no_lzfse.sh）完全不含私有 LZFSE 引擎：binary 內無
# bvx3/other3、LZFSE codec 不可用、LZFSE 封存無法解碼——同時標準 codec 與純 tar
# 仍可用。以完整版（compile_tar.sh）作為「含 LZFSE」的對照。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

LOG="$HERE/test_no_lzfse.log"
exec > >(tee "$LOG") 2>&1
# Neutral temp name (no "lzfse" substring, which would false-match grep checks).
TMP="$(mktemp -d "$HERE/.test_nolz.XXXXXX")"
# Rebuild the full binary at the end so the working tree / install stays full.
# 測試結束重建完整版，讓工作目錄／安裝維持完整版。
cleanup() { rm -rf "$TMP"; ./compile_tar.sh >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

echo "building full + public binaries..."
./compile_tar.sh      >/dev/null 2>&1; cp release/swift_tar "$TMP/full"
./compile_no_lzfse.sh >/dev/null 2>&1; cp release/swift_tar "$TMP/public"
FULL="$TMP/full"; PUB="$TMP/public"

# 1) the private format name must be present in the full binary and ABSENT in
#    the public one (symbols + string literals). / bvx3 在完整版存在、公開版消失。
[ "$(strings "$FULL" | grep -c bvx3)" -gt 0 ] && ok "full build contains bvx3 (control)" \
                                              || bad "full build unexpectedly has no bvx3"
[ "$(strings "$PUB"  | grep -c bvx3)" -eq 0 ] && ok "public build has NO bvx3 in binary" \
                                              || bad "public build still contains bvx3"
[ "$(strings "$PUB"  | grep -c other3)" -eq 0 ] && ok "public build has NO other3 in binary" \
                                                || bad "public build still contains other3"

# 2) public help must not advertise any LZFSE codec / 公開版 help 不得列出 LZFSE codec
if "$PUB" -h | grep -qiE 'lzfse|bvx3|other3'; then bad "public help leaks LZFSE/bvx3/other3"
else ok "public help lists no LZFSE codec"; fi

# A compressible payload large enough to force a real bvx3 block (small inputs
# fall back to LZVN). / 夠大的可壓縮內容以觸發真正的 bvx3 區塊（小輸入會退回 LZVN）。
seq 1 500 > "$TMP/f.txt"

# 3) LZFSE encode flags are unavailable, and the public build says so instead of
#    quietly writing something else. This used to assert a silent fall back to
#    plain tar: the caller asked for --bvx3-fast, got a plain tar, and nothing
#    reported the substitution. That is the same shape as the --to-stdout defect
#    that motivated option validation -- a command doing something other than
#    what was asked, in silence. The flag names are not compiled into this build
#    at all (their absence is what check 2 above verifies with `strings`), so it
#    rejects them as unknown, which is both correct and the only outcome that
#    keeps the private engine's names out of the public binary.
# 3) LZFSE encode 旗標不可用，且公開版會明說，而非默默寫出別的東西。此處原本斷言的是
#    「靜默退回純 tar」：呼叫端要求 --bvx3-fast、拿到純 tar，卻沒有任何地方回報這個替換。
#    那與促成選項驗證的 --to-stdout 缺陷是同一種形狀——指令做了與要求不同的事，且沉默。
#    這些旗標名稱根本沒有編進本版本（上方檢查 2 正是以 `strings` 驗證其不存在），故它會
#    以「未知選項」拒絕；這既正確，也是唯一能讓私有引擎名稱不出現在公開執行檔中的結果。
if "$PUB" -c --bvx3-fast -f "$TMP/pub.bin" -C "$TMP" f.txt >/dev/null 2>&1; then
    bad "public --bvx3-fast was accepted; it should be rejected as unknown"
else
    ok "public --bvx3-fast is rejected rather than silently substituted"
fi
[ -s "$TMP/pub.bin" ] && bad "public --bvx3-fast wrote an archive despite failing" \
                      || ok "public --bvx3-fast wrote nothing"

# 4) public build cannot recover contents from an LZFSE archive made by the full
#    build. Judge by content recovery, not exit code (garbage may read as an
#    empty tar). / 公開版無法從完整版的 LZFSE 封存取回內容；以「是否取回內容」判斷
#    而非 exit code（垃圾位元可能被當成空 tar）。
"$FULL" -c --bvx3-fast -f "$TMP/lz.bvx3" -C "$TMP" f.txt
"$FULL" --identify -f "$TMP/lz.bvx3" | grep -qi 'lzfse' \
    && ok "full build made a real LZFSE archive (control)" \
    || bad "full build did not make an LZFSE archive (test setup)"
if "$PUB" -t -f "$TMP/lz.bvx3" 2>/dev/null | grep -q 'f.txt'; then
    bad "public build listed contents of an LZFSE archive"
else ok "public build cannot list an LZFSE archive"; fi
mkdir -p "$TMP/lzout"
"$PUB" -x -f "$TMP/lz.bvx3" -C "$TMP/lzout" >/dev/null 2>&1 || true
if [ -f "$TMP/lzout/f.txt" ] && cmp -s "$TMP/lzout/f.txt" "$TMP/f.txt"; then
    bad "public build extracted an LZFSE archive"
else ok "public build cannot extract an LZFSE archive"; fi
# the full build still decodes it (sanity) / 完整版仍可解（健全性）
"$FULL" -t -f "$TMP/lz.bvx3" >/dev/null 2>&1 && ok "full build decodes the LZFSE archive (control)" \
                                             || bad "full build failed to decode its own LZFSE archive"

# 5) standard codecs + plain tar still work on the public build /
#    公開版的標準 codec 與純 tar 仍正常
for spec in "plain:" "gzip:--gzip" "zstd:--zstd"; do
    name="${spec%%:*}"; flag="${spec#*:}"
    mkdir -p "$TMP/out_$name"
    # shellcheck disable=SC2086
    "$PUB" -c $flag -f "$TMP/a_$name.tar" -C "$TMP" f.txt
    "$PUB" -x -f "$TMP/a_$name.tar" -C "$TMP/out_$name"
    if cmp -s "$TMP/out_$name/f.txt" "$TMP/f.txt"; then ok "public build round-trips $name"
    else bad "public build failed $name round-trip"; fi
done

# 6) public self-test passes / 公開版自我測試通過
if "$PUB" -test >/dev/null 2>&1; then ok "public build -test passes"; else bad "public build -test failed"; fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
