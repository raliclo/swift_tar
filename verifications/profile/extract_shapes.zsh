#!/usr/bin/env zsh
# =====================================================================
# extract_shapes.zsh -- time swift_tar against a reference tar while extracting
#                       the same archive, across the three shapes the FAQ names.
# extract_shapes.zsh -- 以 FAQ 指名的三種形狀，量測 swift_tar 與參照 tar 解開
#                       同一個封存所需的時間。
#
# 本檔存在的理由是一個被推翻過三次的結論。FAQ 的「解壓差距」一節先後提出過三個機制，
# 每一個都在下一組數字出現時倒下。第四個候選（FileWriterPool 的逐檔緩衝）也已被
# page_fault_attribution.zsh 排除。**在指名第五個機制之前，要先確認那個現象還在。**
#
# This exists because a conclusion has been overturned three times. The FAQ's decode-gap
# section named three mechanisms and each fell to the next set of numbers; a fourth
# candidate was excluded by page_fault_attribution.zsh. Before anyone names a fifth,
# confirm the phenomenon is still there.
#
# 它量的是時間，不是符號。取樣式 profiler 在此無用，原因寫在 README.md 裡：解壓一個
# RAM disk 上的封存只跑約 0.17 秒，四種取樣做法最多只取到 52 個樣本。要先有一個夠大
# 的差距值得 profile，才談得上 profile。
# It measures time, not symbols. Sampling profilers do not work on this target -- see
# README.md -- and there is no point profiling a gap before establishing it exists.
#
# 用法 / Usage:
#   verifications/profile/extract_shapes.zsh              # 量測並印出，不寫檔
#   verifications/profile/extract_shapes.zsh --record     # 另外追加到 extract_shapes.csv2
#   verifications/profile/extract_shapes.zsh --work DIR   # 指定語料所在（預設見下）
#   verifications/profile/extract_shapes.zsh --reps N     # 每個形狀的交錯輪數（預設 5）
#   verifications/profile/extract_shapes.zsh --help
#
# 不加 --record 就不動任何已入版的檔案，與 verifications/ 其他腳本一致。
# Without --record it touches no committed file, as the other scripts here do.
# =====================================================================
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '3,31p' "${0:A}" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE=${0:A:h}
ROOT=${HERE:h:h}
MATRIX="$HERE/extract_shapes.csv2"

. "$ROOT/platform.zsh"
PLAT=$(swift_tar_platform)

WORK=""
REPS=5
RECORD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --record) RECORD=1; shift ;;
    --work)   WORK="${2:?--work needs a path}"; shift 2 ;;
    --reps)   REPS="${2:?--reps needs a number}"; shift 2 ;;
    *) print -ru2 -- "unknown option: $1"; exit 2 ;;
  esac
done

BIN="$ROOT/release/swift_tar"
[[ -f $BIN ]] || BIN="$ROOT/release/swift_tar.exe"
[[ -f $BIN ]] || { print -ru2 -- "no built swift_tar; run the build first / 找不到已建置的 swift_tar"; exit 1 }

# 語料要放在 I/O 最便宜的地方。FAQ 的結論是「差距在 I/O 最便宜時最大」，所以在慢的
# 檔案系統上量會把要看的東西埋掉——那裡量到的是磁碟，不是 tar。
# 預設值依平台選一個記憶體背景的位置；沒有就用 --work 指定。
# The corpus belongs wherever I/O is cheapest. The FAQ's finding is that the gap is widest
# where I/O is cheapest, so measuring on a slow filesystem buries the thing being measured:
# what you get there is the disk, not the tar.
if [[ -z $WORK ]]; then
  case $PLAT in
    linux) WORK=/tmp/extract-shapes ;;          # tmpfs on the appliance / 設備上的 tmpfs
    *)     WORK=${TMPDIR:-/tmp}/extract-shapes ;;
  esac
fi
mkdir -p "$WORK"

# 參照實作以「自我描述」挑選，不以檔名挑選。這棵樹已經為此付過代價：Linux VM 的
# /usr/bin/tar 就是 swift_tar 自己，以該名稱安裝——依檔名挑選會讓 swift_tar 與自己
# 比較，並回報完美的一致。
# The reference is chosen by what it says about itself, never by filename. This tree has
# paid for that: /usr/bin/tar in the Linux VM *is* swift_tar under that name, so choosing
# by filename compares swift_tar with itself and reports flawless agreement.
REF=""; REFDESC=""
for cand in /usr/bin/tar /usr/bin/bsdtar /bin/tar $(whence -ap tar bsdtar gtar 2>/dev/null); do
  [[ -x $cand ]] || continue
  desc=$("$cand" --version 2>&1 | head -1)
  case "$desc" in
    *bsdtar*|*"GNU tar"*) REF=$cand; REFDESC=$desc; break ;;
  esac
done
[[ -n $REF ]] || { print -ru2 -- "no bsdtar or GNU tar found to compare against / 找不到可比對的 bsdtar 或 GNU tar"; exit 1 }

zmodload zsh/datetime
ms() { local t0=$EPOCHREALTIME; "$@" >/dev/null 2>&1; local t1=$EPOCHREALTIME; printf "%.0f" $(( (t1-t0)*1000 )); }

STAMP=$(sed -n 's/^swift_tar_version=//p' "$ROOT/version-$PLAT.txt" 2>/dev/null | sed -n '1p')
[[ -n $STAMP ]] || STAMP="(none)"
LOADAVG=$(uptime | sed -n 's/.*averages*: *\([0-9.]*\).*/\1/p')

print -- "extract shapes / 解壓形狀   platform=$PLAT  reps=$REPS"
print -- "  swift_tar : $STAMP"
print -- "  reference : $REFDESC"
print -- "             $REF"
print -- "  work      : $WORK"
print -- "  load      : $LOADAVG"
print --
print -- "  形狀 shape        swift_tar   reference   ratio"

typeset -a ROWS
# 三種形狀取自 FAQ 的表，總量刻意不同——那張表就是這樣量的，改動它會使兩邊無法並排。
# The three shapes come from the FAQ's table, unequal totals included: that is how the
# table was measured, and changing them would stop the two being comparable.
for shape in "20 8192" "200 800" "2000 80"; do
  count=${shape%% *}; kb=${shape##* }
  label="${count}x$(( kb >= 1024 ? kb/1024 : kb ))$( (( kb >= 1024 )) && print -n MB || print -n KB)"

  rm -rf "$WORK/src" "$WORK/a.tar"; mkdir -p "$WORK/src"
  for i in $(seq 1 $count); do dd if=/dev/urandom of="$WORK/src/f$i" bs=1k count=$kb 2>/dev/null; done
  "$BIN" -c -f "$WORK/a.tar" -C "$WORK" src
  rm -rf "$WORK/src"

  # 交錯執行，取最小值。交錯是為了讓兩者遇到同一段背景負載；最小值是因為干擾只會使
  # 時間變長，不會使它變短，故最小值是最接近「沒有干擾」的那一次。
  # Interleaved, minimum taken. Interleaving exposes both to the same background load;
  # the minimum is used because interference only ever adds time, so the smallest run is
  # the one least contaminated.
  amin=999999; bmin=999999
  for r in $(seq 1 $REPS); do
    rm -rf "$WORK/out"; mkdir -p "$WORK/out"
    a=$(ms "$BIN" -x -f "$WORK/a.tar" -C "$WORK/out")
    rm -rf "$WORK/out"; mkdir -p "$WORK/out"
    b=$(ms "$REF" -x -f "$WORK/a.tar" -C "$WORK/out")
    (( a < amin )) && amin=$a
    (( b < bmin )) && bmin=$b
  done
  rm -rf "$WORK/out" "$WORK/a.tar"

  ratio=$(printf "%.2f" $(( amin * 1.0 / bmin )))
  printf "  %-16s %6s ms  %6s ms   %sx\n" "$label" "$amin" "$bmin" "$ratio"
  ROWS+=("$PLAT,$label,$count,$(( kb * 1024 )),$amin,$bmin,$ratio,$STAMP,\"$REFDESC\",$WORK,$LOADAVG")
done

rmdir "$WORK" 2>/dev/null || true

print --
print -- "  ratio < 1 表示 swift_tar 較快 / below 1 means swift_tar is faster"

if (( RECORD )); then
  WHEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ ! -f $MATRIX ]]; then
    {
      print -- "platform,shape,files,file_bytes,swift_tar_ms,reference_ms,ratio,swift_tar_version,reference,work,loadavg,recorded_utc"
      print -- "平台,形狀,檔數,每檔位元組,swift_tar毫秒,參照毫秒,比值,版本戳,參照實作,語料位置,負載,記錄時間UTC"
    } > "$MATRIX"
  fi
  for row in "${ROWS[@]}"; do csv2 -append "$row,$WHEN" -i "$MATRIX" --in-place; done
  print -- "  recorded / 已記錄： $MATRIX"
else
  print -- "  pass --record to append to extract_shapes.csv2 / 加上 --record 才會寫入"
fi
