#!/bin/zsh
# =====================================================================
# make_fixtures.zsh -- regenerate the committed RGB1 test fixtures.
# make_fixtures.zsh -- 重新產生入版的 RGB1 測試 fixture。
#
# The fixtures are four small real video frames, committed because
# mixed_size_delta.zsh needs real image content and a correctness test must not
# depend on a 285 MB corpus that is not in the repository, or on a volume being
# mounted. Total 34 KB.
# 這些 fixture 是四張小尺寸的真實視訊影格，之所以入版，是因為 mixed_size_delta.zsh
# 需要真實影像內容，而正確性測試不應依賴一份不入版的 285 MB 語料，也不應依賴某個磁碟區
# 是否掛載。四檔共 34 KB。
#
# This script exists so the fixtures' provenance is executable rather than
# prose. A committed binary with no way to say where it came from is a fact
# nobody can check.
# 本腳本的存在，是為了讓 fixture 的來源可被執行而非僅以文字描述。一個入版的二進位檔
# 若無從說明其來源，就是一項沒有人能查核的事實。
#
# Source identity, not source path / 以來源身分而非來源路徑記錄:
#
#   file    20260803 回到神面前 讓神來醫治 [恩典365 - 時代先知 ： 耶利米 系列]
#           [d-t779PY_S0].webm
#   size    69,713,041 bytes
#   sha256  2e463bd12fda31aa2d10dec66b4f370d18458841bee27e1d8cd3fb26053df891
#   frames  frames 0 and 2 at t=121.2 s (duration/2), scaled down; see
#           make_consecutive_corpus.zsh. Frames 0 and 1 are byte-identical.
#
# The absolute path is deliberately not recorded. It is /Volumes/... on the
# machine this was built on and would be wrong everywhere else, whereas the hash
# identifies the file wherever it sits. Pass the path as $1.
# 刻意不記錄絕對路徑。它在建置這批 fixture 的機器上是 /Volumes/...，在其他任何地方都
#是錯的；而雜湊值無論檔案位於何處都能辨識它。路徑請以 $1 傳入。
#
# Usage / 用法:
#   ./make_fixtures.zsh <source-video>
# =====================================================================
set -euo pipefail

# --help answers before any work starts / --help 在任何工作開始前先回答。
script_path="${0:A}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,37p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

HERE="${0:A:h}"
ST="${SWIFT_TAR:-${HERE:h:h:h}/release/swift_tar}"
SRC="${1:?usage: $0 <source-video> / 用法：$0 <來源影片>}"
EXPECT_SHA=2e463bd12fda31aa2d10dec66b4f370d18458841bee27e1d8cd3fb26053df891

[[ -f "$SRC" ]] || { print -ru2 -- "[Error] no such file: $SRC"; exit 1 }
[[ -x "$ST"  ]] || { print -ru2 -- "[Error] no swift_tar at $ST"; exit 1 }
command -v ffmpeg >/dev/null || { print -ru2 -- "[Error] ffmpeg required"; exit 1 }

# A different source silently produces different fixtures, and a test whose
# inputs changed without anyone noticing reports on something else entirely.
# 換了來源會靜默產生不同的 fixture，而輸入在無人察覺下改變的測試，回報的已是另一件事。
got=$(sha256sum "$SRC" | cut -d' ' -f1)
if [[ "$got" != "$EXPECT_SHA" ]]; then
    print -ru2 -- "[Error] source sha256 mismatch / 來源雜湊不符"
    print -ru2 -- "        expected $EXPECT_SHA"
    print -ru2 -- "        got      $got"
    print -ru2 -- "        pass --force to regenerate from a different source"
    [[ "${2:-}" == "--force" ]] || exit 1
    print -ru2 -- "        --force given; continuing / 已指定 --force，繼續執行"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fixtures.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
# Never start inside the opening 30 s, and enforce it hardest when the selection
# is small. A clip's first seconds are where fades, title cards and static holds
# live: the 8 frames taken at t=0 that produced the 122 Mbps bitrate figure
# compressed to 7% of raw where real content gives 50%. A large sample dilutes
# that; a sample under 10 frames is dominated by it.
# 起點一律不落在片頭 30 秒內，且在選取格數少時檢查最嚴。影片開頭正是淡入、標題卡與
# 靜止畫面所在：先前產出 122 Mbps 那個數字的 t=0 八格，壓縮到原始的 7%，而真實內容為
# 50%。樣本大時該影響會被稀釋，樣本少於 10 格時則由它主導。
MIN_START=30
START=$(python3 -c "print(f'{max(float('$DUR')/2, $MIN_START):.1f}')")
(( $(python3 -c "print(1 if float('$START') >= $MIN_START or 3 >= 10 else 0)") )) || {
    print -ru2 -- "[Error] START=${START}s is inside the opening ${MIN_START}s with only 3 frames"
    print -ru2 -- "        起點 ${START} 秒落在片頭 ${MIN_START} 秒內，且僅取 3 格"
    exit 1
}

# Frames 0 and 2, not 0 and 1. The first two frames of this clip at t=121.2 s
# are byte-identical -- the only duplicate pair in the 48-frame corpus, and the
# pair this script originally picked. A fixture pair that is meant to be two
# different frames must be checked, not assumed: the size discriminator in
# mixed_size_delta.zsh still passes on a duplicate pair, it just stops testing
# what it says it tests.
# 取第 0 與第 2 格，而非第 0 與第 1 格。本片 t=121.2 秒起的前兩格位元組完全相同——那是
# 48 格語料中唯一的重複配對，也正是本腳本最初挑中的那一對。宣稱「兩張不同影格」的
# fixture 配對必須經過檢查而非假設：mixed_size_delta.zsh 的體積判別式在重複配對上依然
# 會通過，只是它不再測試它所宣稱測試的東西。
ffmpeg -v error -ss "$START" -i "$SRC" -frames:v 3 -pix_fmt rgb24 -f rawvideo "$TMP/three.rgb24" -y

# frame-index : width : height : output name
# 影格索引 : 寬 : 高 : 輸出檔名
# The two 64x48 fixtures must differ, or the pair proves nothing.
# 兩張 64x48 fixture 必須不同，否則該配對什麼也證明不了。
FB=$((1920*1080*3))
h0=$(dd if="$TMP/three.rgb24" bs=$FB skip=0 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
h2=$(dd if="$TMP/three.rgb24" bs=$FB skip=2 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
[[ "$h0" != "$h2" ]] || {
    print -ru2 -- "[Error] frames 0 and 2 are identical; pick different indices"
    print -ru2 -- "        第 0 與第 2 格相同，請改用其他索引"
    exit 1
}

for spec in "0:64:48:a_64x48" "2:64:48:b_64x48" "0:32:24:small_32x24" "0:48:64:rot_48x64"; do
    idx="${spec%%:*}"; r="${spec#*:}"; w="${r%%:*}"; r="${r#*:}"; h="${r%%:*}"; name="${r##*:}"
    dd if="$TMP/three.rgb24" of="$TMP/f.rgb24" bs=$((1920*1080*3)) skip="$idx" count=1 2>/dev/null
    ffmpeg -v error -f rawvideo -pix_fmt rgb24 -s 1920x1080 -i "$TMP/f.rgb24" \
           -vf "scale=$w:$h" -pix_fmt rgb24 -f rawvideo "$TMP/s.rgb24" -y
    "$ST" --rgb1-pack --width "$w" --height "$h" \
          --lat 25.033 --lng 121.5654 --height-m 10 \
          --title "fixture ${w}x${h} frame $idx" --country TW \
          --creator-email fixture@swift-tar.local --right CcBy --created-ms 0 \
          -f "$HERE/$name.rgb1" "$TMP/s.rgb24" >/dev/null
    print -- "  $name.rgb1  ($(stat -f %z "$HERE/$name.rgb1") B)"
done

print -- "[Done] fixtures regenerated / 已重新產生 fixture"
