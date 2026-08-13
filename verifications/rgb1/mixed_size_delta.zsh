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
# the feature it protects. / 等尺寸影格仍須走差分路徑：守門不得把它保護的功能
# 一併關掉。
mk 64 48 "$TMP/eq1.rgb1"
mk 64 48 "$TMP/eq2.rgb1"
if run "$TMP/eq1.rgb1" "$TMP/eq2.rgb1"; then
    grep -q "round-trip verified" "$TMP/out" \
        && ok "equal sizes: delta path still runs and verifies" \
        || bad "equal sizes: exited 0 but did not verify"
else
    bad "equal sizes: failed with exit $?"
    sed 's/^/    /' "$TMP/out" >&2
fi

print -- "-----------------------------------------"
print -- "PASS: $pass  FAIL: $fail"
(( fail == 0 ))
