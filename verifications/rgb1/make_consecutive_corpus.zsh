#!/bin/zsh
# =====================================================================
# make_consecutive_corpus.zsh -- build a consecutive-frame RGB1 corpus.
# make_consecutive_corpus.zsh -- 產生連續影格的 RGB1 語料。
#
# rgb1_sampler pulls one frame every N seconds from t=0. That corpus opens on
# this clip's fade from black, a frame that compresses ~300x better than real
# content and drags every corpus average down, and its neighbours are 10 s apart
# so they say nothing about what a 60 fps streamer actually sends. This takes N
# consecutive frames from mid-video instead.
# rgb1_sampler 自 t=0 起每 N 秒取一格。該語料的開頭是本片自黑畫面淡入的那格，
# 其壓縮率較真實內容好約 300 倍，會拉低整份語料的平均；且相鄰影格相隔 10 秒，
# 無法反映 60 fps 串流器實際送出的內容。本腳本改為自影片中段取 N 格連續影格。
#
# The start point is duration/2, the same expression batch_vs_per_frame.zsh uses,
# so both scripts land on the same footage.
# 起點取 duration/2，與 batch_vs_per_frame.zsh 使用相同算式，使兩支腳本落在同一段
# 影片上。
#
# Frames are named by index, not timestamp: 48 consecutive frames span ~1.6 s at
# 30 fps, so second-resolution names would collide.
# 檔名以索引而非時間戳命名：30 fps 下 48 格連續影格僅橫跨約 1.6 秒，秒級解析度的
# 檔名會碰撞。
#
# Usage / 用法:
#   ./make_consecutive_corpus.zsh [source-video] [frame-count] [out-dir]
#   defaults / 預設: 48 frames, ./sample_consecutive
# =====================================================================
set -euo pipefail

HERE="${0:A:h}"
DEFAULT_SRC="/Volumes/Windows/proj_Win/swift-cross-ui/testapp/output/20260803 回到神面前 讓神來醫治 [恩典365 - 時代先知 ： 耶利米 系列] [d-t779PY_S0].webm"
SRC="${1:-$DEFAULT_SRC}"
FRAMES="${2:-48}"
OUT="${3:-$HERE/sample_consecutive}"
ST="${SWIFT_TAR:-${HERE:h:h}/release/swift_tar}"

for tool in ffmpeg ffprobe python3; do
    command -v "$tool" >/dev/null || { print -ru2 -- "[Error] $tool required / 需要 $tool"; exit 1 }
done
[[ -f "$SRC" ]] || { print -ru2 -- "[Error] source not found: $SRC"; exit 1 }
[[ -x "$ST"  ]] || { print -ru2 -- "[Error] no swift_tar at $ST — run compile_tar.sh"; exit 1 }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/consecutive.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")
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
MID=$(python3 -c "print(f'{max(float('$DUR')/2, $MIN_START):.1f}')")
(( $(python3 -c "print(1 if float('$MID') >= $MIN_START or $FRAMES >= 10 else 0)") )) || {
    print -ru2 -- "[Error] MID=${MID}s is inside the opening ${MIN_START}s with only $FRAMES frames"
    print -ru2 -- "        起點 ${MID} 秒落在片頭 ${MIN_START} 秒內，且僅取 $FRAMES 格"
    exit 1
}

FB=$((W * H * 3))

print -- "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
print -- "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
print -- "[Info] source / 來源: ${SRC:t}  ${W}x${H}"
print -- "[Info] start / 起點: t=${MID}s, ${FRAMES} consecutive frames / 連續影格"
print -- "[Info] output / 輸出: $OUT/"

# Existing frames are removed rather than merged over: a corpus half from one run
# and half from another is worse than no corpus, and every consumer of this
# directory globs *.rgb1.
# 既有影格直接清除而非疊加：一半來自這次、一半來自上次的語料比沒有語料更糟，而所有
# 使用本目錄的腳本都是以 *.rgb1 展開。
mkdir -p "$OUT"
stale=("$OUT"/*.rgb1(N))
(( ${#stale} )) && { rm -f "${stale[@]}"; print -- "[Clean] removed ${#stale} stale frame(s) / 已移除既有影格" }

ffmpeg -v error -ss "$MID" -i "$SRC" -frames:v "$FRAMES" \
       -pix_fmt rgb24 -f rawvideo "$TMP/raw.rgb24" -y

got=$(( $(stat -f %z "$TMP/raw.rgb24") / FB ))
(( got == FRAMES )) || { print -ru2 -- "[Error] wanted $FRAMES frames, got $got / 取得影格數不符"; exit 1 }

for ((i = 0; i < FRAMES; i++)); do
    dd if="$TMP/raw.rgb24" of="$TMP/f.rgb24" bs="$FB" skip="$i" count=1 2>/dev/null
    "$ST" --rgb1-pack --width "$W" --height "$H" \
          --lat 25.033 --lng 121.5654 --height-m 10 \
          --title "consecutive t+${MID}s frame $i" --country TW \
          --creator-email sampler@swift-tar.local --right CcBy --created-ms 0 \
          -f "$(printf '%s/f%03d.rgb1' "$OUT" "$i")" "$TMP/f.rgb24"
done

print -- "[Done] wrote $FRAMES RGB1 containers / 已寫出 $FRAMES 個 RGB1 容器"
print -- "       $FB B payload + 876 B header each / 每個 payload $FB B 加 876 B 標頭"
