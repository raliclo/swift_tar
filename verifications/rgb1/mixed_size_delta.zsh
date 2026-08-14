#!/bin/zsh
# =====================================================================
# mixed_size_delta.zsh -- the delta guards on both sides must agree.
# mixed_size_delta.zsh -- 差分守門在編碼與解碼兩端必須一致。
#
# encodeBand skips the inter-frame delta when the previous frame is a different
# size (prev.count == payload.count). decodeBand sees only its own band and
# cannot know the frame size, so the mirroring guard lives at the decode call
# site. Without it a mixed-size corpus -- swift_tar_DOE accepts any file list --
# reconstructs wrongly, and a *smaller* previous frame runs off the end of
# prev[base + i] and traps (exit 133).
# encodeBand 在前一格尺寸不同時會跳過影格間差分（prev.count == payload.count）。
# decodeBand 只看得到自己那條 band，無從得知整格大小，故鏡像守門置於解碼呼叫端。
# 若缺少它，尺寸混雜的語料（swift_tar_DOE 接受任意檔案清單）會重建錯誤，而前一格
# 「較小」時更會在 prev[base + i] 越界並 trap（exit 133）。
#
# Usage / 用法:
#   ./mixed_size_delta.zsh
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
DOE="${DOE:-$HERE/swift_tar_DOE}"
ST="${SWIFT_TAR:-${HERE:h:h}/release/swift_tar}"

[[ -x "$DOE" ]] || { print -ru2 -- "no swift_tar_DOE at $DOE — build it first"; exit 1 }
[[ -x "$ST"  ]] || { print -ru2 -- "no swift_tar at $ST — run compile_tar.sh"; exit 1 }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { print -- "PASS: $1"; (( ++pass )) }
bad() { print -- "FAIL: $1"; (( ++fail )) }

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
print -- "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print -- "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
print -- "[Info] swift_tar_DOE: $DOE"

# Two frames of deliberately different sizes / 兩格刻意不同尺寸
mk() { # w h out
    head -c $(( $1 * $2 * 3 )) /dev/urandom > "$TMP/raw"
    "$ST" --rgb1-pack --width "$1" --height "$2" --lat 0 --lng 0 --height-m 0 \
          --title t --country TW --creator-email a@b.co --right R --created-ms 0 \
          -f "$3" "$TMP/raw"
}
mk 64 48 "$TMP/big.rgb1"
mk 32 24 "$TMP/small.rgb1"

# Either order must succeed. The delta is simply skipped, exactly as the encode
# side already does, so --verify's round-trip check has to pass.
# 兩種順序都必須成功：差分被跳過（與編碼端行為一致），故 --verify 的往返檢查
# 必須通過。
run() { "$DOE" --codec zstd --delta --repeat 1 "$1" "$2" > "$TMP/out" 2>&1 }

if run "$TMP/small.rgb1" "$TMP/big.rgb1"; then
    grep -q "round-trip verified" "$TMP/out" \
        && ok "smaller-then-larger: no trap, round-trip verified" \
        || bad "smaller-then-larger: exited 0 but did not verify"
else
    rc=$?
    (( rc == 133 )) \
        && bad "smaller-then-larger: trapped (exit 133) — the decode guard is missing" \
        || bad "smaller-then-larger: failed with exit $rc"
    sed 's/^/    /' "$TMP/out" >&2
fi

if run "$TMP/big.rgb1" "$TMP/small.rgb1"; then
    grep -q "round-trip verified" "$TMP/out" \
        && ok "larger-then-smaller: no mismatch, round-trip verified" \
        || bad "larger-then-smaller: exited 0 but did not verify"
else
    bad "larger-then-smaller: failed with exit $? (a size mismatch must not reconstruct wrongly)"
    sed 's/^/    /' "$TMP/out" >&2
fi

# Equal-size frames must still take the delta path — the guard must not disable
# the feature it protects. The second frame is a copy of the first, which makes
# the delta's effect unmistakable: an all-zero residual compresses to a fraction
# of the noise it came from. Two *independent* noise frames would not work here
# — zstd stores incompressible input verbatim, so the delta of two noise frames
# is a different byte sequence of exactly the same compressed size.
# 等尺寸影格仍須走差分路徑：守門不得把它保護的功能一併關掉。第二格取第一格的複本，
# 使差分的效果無可爭辯：全零殘差壓縮後只剩原雜訊的一小部分。此處不能改用兩張
# *獨立* 的雜訊影格——zstd 對不可壓縮的輸入是原樣儲存，故兩張雜訊影格的差分雖是
# 不同的位元組序列，壓縮後大小卻完全相同。
mk 64 48 "$TMP/eq1.rgb1"
cp "$TMP/eq1.rgb1" "$TMP/eq2.rgb1"
if run "$TMP/eq1.rgb1" "$TMP/eq2.rgb1"; then
    grep -q "round-trip verified" "$TMP/out" \
        && ok "equal sizes: round-trip verifies" \
        || bad "equal sizes: exited 0 but did not verify"
else
    bad "equal sizes: failed with exit $?"
    sed 's/^/    /' "$TMP/out" >&2
fi

# ...and "round-trip verified" alone cannot show the delta ran. report() prints
# that string from opt.verify alone, so it stays true when the delta is skipped
# — skipping a delta is a *correct* transform, which is exactly the silent no-op
# this file exists to catch. The compressed size is the discriminator.
# ……而單憑「round-trip verified」無法證明差分有執行。report() 僅依 opt.verify 印出
# 該字串，故差分被跳過時它依然為真——跳過差分本身是*正確*的變換，而這正是本檔要
# 攔截的靜默 no-op。判別依據是壓縮後大小。
bytes() { "$DOE" --codec zstd --repeat 1 --csv "$@" 2>/dev/null | tail -1 | cut -d, -f4 }
with=$(bytes --delta "$TMP/eq1.rgb1" "$TMP/eq2.rgb1")   || with=""
without=$(bytes "$TMP/eq1.rgb1" "$TMP/eq2.rgb1")        || without=""
if [[ -z "$with" || -z "$without" ]]; then
    bad "equal sizes: --csv produced no compressed_bytes (with='$with' without='$without')"
elif [[ "$with" == "$without" ]]; then
    bad "equal sizes: --delta produced identical bytes ($with) — the delta did not run"
else
    ok "equal sizes: delta actually ran ($with vs $without B)"
fi

# Same byte count, different geometry. 64x48 and 48x64 are both 9216 B, so a
# guard that only compares sizes lets the delta through — and then the two sides
# disagree, because they slice those 9216 bytes into different band layouts. The
# guard compares width and height for exactly this pair.
# 位元組數相同但幾何不同。64x48 與 48x64 皆為 9216 B，僅比對大小的守門會放行差分
# ——而兩端隨即分歧，因為它們把這 9216 個位元組切成不同的列帶佈局。守門改比對寬與高
# 正是為了這組情形。
#
# --slices 3 is required to expose it. At the default of 1 slice both frames are
# a single 9216 B band, the layouts coincide, and a size-only guard survives. At
# 3 slices 64x48 gives 3 bands of 3072 B while 48x64 gives 3168/3168/2880.
# 必須加上 --slices 3 才能暴露此問題。在預設的 1 個 slice 下，兩格皆為單一 9216 B
# 的列帶，佈局恰好一致，僅比對大小的守門不會出錯。切成 3 條時，64x48 為 3 條
# 3072 B，而 48x64 為 3168／3168／2880。
mk 64 48 "$TMP/geo1.rgb1"
mk 48 64 "$TMP/geo2.rgb1"
run() { "$DOE" --codec zstd --delta --slices 3 --repeat 1 "$1" "$2" > "$TMP/out" 2>&1 }
if run "$TMP/geo1.rgb1" "$TMP/geo2.rgb1"; then
    grep -q "round-trip verified" "$TMP/out" \
        && ok "same bytes, different geometry: delta skipped, round-trip verified" \
        || bad "same bytes, different geometry: exited 0 but did not verify"
else
    rc=$?
    (( rc == 133 )) \
        && bad "same bytes, different geometry: trapped (exit 133) — the geometry guard is missing" \
        || bad "same bytes, different geometry: failed with exit $rc"
    sed 's/^/    /' "$TMP/out" >&2
fi

print -- "-----------------------------------------"
print -- "PASS: $pass  FAIL: $fail"
(( fail == 0 ))
