#!/usr/bin/env zsh
# test_rgb1.zsh
# Verify swift_tar's RGB1 raw-image container: --rgb1-pack / --rgb1-info /
# --rgb1-raw. Covers header layout (magic + fixed 876-byte header), payload
# round-trip, big-endian geo (E7) precision, ASCII field validation, stdin/
# stdout streaming, and the argument guards. RGB1 is self-contained (rgb1.swift)
# and works in both the full and --no-lzfse builds.
# 驗證 swift_tar 的 RGB1 原始影像容器：--rgb1-pack / --rgb1-info / --rgb1-raw。
# 涵蓋 header 佈局（magic + 固定 876-byte header）、payload round-trip、大端
# geo（E7）精度、ASCII 欄位驗證、stdin/stdout 串流與參數守衛。RGB1 自足
# （rgb1.swift），全功能版與 --no-lzfse 版皆可用。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$HERE/release/swift_tar.exe" ;;
    *) ST="$HERE/release/swift_tar" ;;
  esac
fi

if [ ! -x "$ST" ]; then
  echo "error: build first (./compile_tar.zsh) — missing $ST" >&2
  exit 1
fi

# Keep the test output log in the script's own folder / 測試輸出 log 保存在腳本同一層資料夾
LOG="$HERE/test_rgb1.log"
exec > >(tee "$LOG") 2>&1

# Temp working dir lives in the same folder, and is removed when done /
# 暫存工作資料夾建在同一層，測試結束即移除
TMP="$(mktemp -d "$HERE/.test_rgb1.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

HEADER_SIZE=876   # 32 base + 64 title + 512 country + 254 email + 4 right + 8 created + 2 tz

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
echo "[Info] swift_tar: $ST"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { # desc want got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2] got [$3])"; fi
}
field() { "$ST" --rgb1-info -f "$1" | grep "^$2=" | cut -d= -f2-; }

# A 3x2 image → 3*2*3 = 18 payload bytes / 3×2 影像 → 18 payload bytes
RAW="$TMP/in.rgb"
printf 'ABCDEFGHIJKLMNOPQR' > "$RAW"   # exactly 18 bytes
RGB1="$TMP/out.rgb1"

"$ST" --rgb1-pack --width 3 --height 2 \
      --lat 25.0334567 --lng 121.5678901 --height-m 12.345 \
      --title "Taipei 101" --country "Taiwan" \
      --creator-email "photog@example.com" --right "CcBy" \
      --created-ms 1700000000123 --tz-offset-min 480 \
      -f "$RGB1" "$RAW"

# ---------------------------------------------------------------------------
# 1) Container layout: magic "RGB1" + total size == header(876) + payload(18)
#    容器佈局：magic「RGB1」+ 總大小 == header(876) + payload(18)
# ---------------------------------------------------------------------------
eq "layout: magic bytes are RGB1" "RGB1" "$(head -c 4 "$RGB1")"
eq "layout: file size == header + payload" "$((HEADER_SIZE + 18))" "$(wc -c < "$RGB1" | tr -d ' ')"

# ---------------------------------------------------------------------------
# 2) Info fields decode to what was packed / info 欄位解回打包時的值
# ---------------------------------------------------------------------------
eq "info: format"    "RGB1"   "$(field "$RGB1" format)"
eq "info: width"     "3"      "$(field "$RGB1" width)"
eq "info: height"    "2"      "$(field "$RGB1" height)"
eq "info: title"     "Taipei 101" "$(field "$RGB1" title)"
eq "info: country"   "Taiwan" "$(field "$RGB1" country)"
eq "info: email"     "photog@example.com" "$(field "$RGB1" creator_email)"
eq "info: right"     "CcBy"   "$(field "$RGB1" right)"
eq "info: created_ms" "1700000000123" "$(field "$RGB1" created_unix_ms)"
eq "info: tz offset (explicit 480)" "480" "$(field "$RGB1" timezone_offset_minutes)"
eq "info: payload_bytes" "18" "$(field "$RGB1" payload_bytes)"

# geo stored as E7 / mm and printed back at fixed precision
eq "info: latitude E7 round-trip"  "25.0334567"  "$(field "$RGB1" latitude)"
eq "info: longitude E7 round-trip" "121.5678901" "$(field "$RGB1" longitude)"
eq "info: height_m mm round-trip"  "12.345"      "$(field "$RGB1" height_m)"

# ---------------------------------------------------------------------------
# 3) Payload round-trip: --rgb1-raw strips the header, bytes match the source.
#    payload round-trip：--rgb1-raw 移除 header，位元組與來源一致。
# ---------------------------------------------------------------------------
"$ST" --rgb1-raw -f "$RGB1" > "$TMP/back.rgb"
if cmp -s "$RAW" "$TMP/back.rgb"; then ok "raw: payload round-trips byte-for-byte"; else bad "raw: payload differs"; fi

# ---------------------------------------------------------------------------
# 4) tz-offset default is Taiwan (480) when the flag is omitted.
#    省略旗標時 tz-offset 預設為台灣（480）。
# ---------------------------------------------------------------------------
printf 'XYZ' > "$TMP/one.rgb"   # 1x1 → 3 payload bytes
"$ST" --rgb1-pack --width 1 --height 1 --lat 0 --lng 0 --height-m 0 \
      --title t --country TW --creator-email a@b.co --right R \
      --created-ms 0 -f "$TMP/def.rgb1" "$TMP/one.rgb"
eq "default tz-offset is 480 (TW)" "480" "$(field "$TMP/def.rgb1" timezone_offset_minutes)"

# ---------------------------------------------------------------------------
# 5) stdin → stdout streaming: pack from '-' and strip to '-' round-trips.
#    stdin → stdout 串流：以 '-' 打包並以 '-' 取出，round-trip。
# ---------------------------------------------------------------------------
printf 'ABCDEFGHIJKLMNOPQR' \
  | "$ST" --rgb1-pack --width 3 --height 2 --lat 1 --lng 2 --height-m 3 \
          --title s --country c --creator-email a@b.co --right R \
          --created-ms 1 -f - > "$TMP/stream.rgb1"
"$ST" --rgb1-raw -f "$TMP/stream.rgb1" > "$TMP/stream_back.rgb"
if [ "$(wc -c < "$TMP/stream.rgb1" | tr -d ' ')" = "$((HEADER_SIZE + 18))" ] \
   && cmp -s "$RAW" "$TMP/stream_back.rgb"; then
  ok "stdin/stdout: pack from stdin round-trips"
else
  bad "stdin/stdout: streaming round-trip failed"
fi

# ---------------------------------------------------------------------------
# 6) Rejections (each must fail and, for pack, write no output file).
#    拒絕案例（每個都須失敗；pack 案例不得產生輸出檔）。
# ---------------------------------------------------------------------------
reject_pack() { # desc  extra-args...  (payload is the 18-byte RAW unless size test)
  local desc="$1"; shift
  local out="$TMP/rej.rgb1"; rm -f "$out"
  if "$ST" --rgb1-pack -f "$out" "$@" >/dev/null 2>&1; then
    bad "$desc (command unexpectedly succeeded)"
  elif [ -e "$out" ]; then
    bad "$desc (failed but left an output file)"
  else
    ok "$desc"
  fi
}

# payload size mismatch: claims 4x4 (48 bytes) but RAW is 18
reject_pack "reject: payload size mismatch" \
  --width 4 --height 4 --lat 0 --lng 0 --height-m 0 \
  --title t --country c --creator-email a@b.co --right R --created-ms 0 "$RAW"
# out-of-range latitude (>90)
reject_pack "reject: latitude out of range" \
  --width 3 --height 2 --lat 91 --lng 0 --height-m 0 \
  --title t --country c --creator-email a@b.co --right R --created-ms 0 "$RAW"
# invalid email (no @)
reject_pack "reject: malformed creator email" \
  --width 3 --height 2 --lat 0 --lng 0 --height-m 0 \
  --title t --country c --creator-email notanemail --right R --created-ms 0 "$RAW"
# invalid right code (digits not allowed)
reject_pack "reject: non-alpha rights code" \
  --width 3 --height 2 --lat 0 --lng 0 --height-m 0 \
  --title t --country c --creator-email a@b.co --right 12 --created-ms 0 "$RAW"
# missing required arg (--height)
reject_pack "reject: missing required --height" \
  --width 3 --lat 0 --lng 0 --height-m 0 \
  --title t --country c --creator-email a@b.co --right R --created-ms 0 "$RAW"

# short header on --rgb1-info
printf 'RGB1short' > "$TMP/short.rgb1"
if "$ST" --rgb1-info -f "$TMP/short.rgb1" >/dev/null 2>&1; then
  bad "reject: --rgb1-info on truncated header"
else
  ok "reject: --rgb1-info on truncated header"
fi

# two RGB1 commands at once
if "$ST" --rgb1-info --rgb1-raw -f "$RGB1" >/dev/null 2>&1; then
  bad "reject: two RGB1 commands at once"
else
  ok "reject: two RGB1 commands at once"
fi

# non-RGB1 file rejected by --rgb1-info
head -c 900 /dev/zero > "$TMP/zeros.bin"
if "$ST" --rgb1-info -f "$TMP/zeros.bin" >/dev/null 2>&1; then
  bad "reject: --rgb1-info on non-RGB1 magic"
else
  ok "reject: --rgb1-info on non-RGB1 magic"
fi

# ---------------------------------------------------------------------------
# Negative geo values must survive the CLI. Combined-short-flag expansion used
# to split any single-dash token longer than two characters, so --lat -33.8688
# became -3 -3 -. -8 -6 -8 -8 and the container was written with latitude
# -3.0000000, exit 0, no message. Southern latitudes, western longitudes,
# below-sea-level heights, pre-1970 timestamps and every Americas timezone were
# affected. Nothing covered negative values, which is why it survived.
# 負數地理值必須能通過 CLI。combined short flag 展開原本會拆開任何長度超過兩字元的
# 單槓詞元，於是 --lat -33.8688 變成 -3 -3 -. -8 -6 -8 -8，容器就以緯度 -3.0000000
# 寫出、結束碼 0、毫無訊息。南半球緯度、西經、海平面以下高度、1970 年前時間戳與整個
# 美洲的時區皆受影響。先前沒有任何測試涵蓋負值，這正是它得以存活的原因。
NEG="$TMP/neg.rgb1"
"$ST" --rgb1-pack --width 3 --height 2 \
      --lat -33.8688 --lng -151.2093 --height-m -430.5 \
      --title "negative geo" --country AU --creator-email a@b.co --right R \
      --created-ms -1000000000 --tz-offset-min -480 \
      -f "$NEG" "$RAW" >/dev/null 2>&1

neg_field() { "$ST" --rgb1-info -f "$NEG" | grep -i "^$1=" | cut -d= -f2; }
for spec in "latitude:-33.8688000" "longitude:-151.2093000" "height_m:-430.500" \
            "created_unix_ms:-1000000000" "timezone_offset_minutes:-480"; do
  key="${spec%%:*}"; want="${spec##*:}"; got="$(neg_field "$key")"
  if [ "$got" = "$want" ]; then
    ok "negative $key survives the CLI ($got)"
  else
    bad "negative $key mangled: got $got, want $want"
  fi
done

# The fix must not stop -czf and czf from expanding, which is what the
# expansion exists for.
# 該修正不得使 -czf 與 czf 停止展開，那正是展開機制存在的理由。
for form in "-czf" "czf"; do
  arc="$TMP/comb_$form.tar.gz"
  if "$ST" "$form" "$arc" -C "$TMP" "$(basename "$RGB1")" >/dev/null 2>&1 && [ -s "$arc" ]; then
    ok "combined flags still expand ($form)"
  else
    bad "combined flags broken ($form)"
  fi
done

# Unknown options must be rejected on the RGB1 paths too. Validation used to sit
# below the command branches, and the RGB1 modes return before reaching it, so
# they were the one family that never saw the check: --titel WRONG wrote a
# container and exited 0. That is the silent acceptance the check exists to
# remove, surviving where the check could not reach.
# 未知選項在 RGB1 路徑上同樣必須被拒。驗證原本位於命令分支之下，而 RGB1 模式在抵達
# 之前就返回，故它們是唯一從未經過檢查的一族：--titel WRONG 會寫出容器並以 0 結束。
# 那正是本檢查所要消除的靜默接受，只是存活在檢查搆不到之處。
BASE=(--rgb1-pack --width 4 --height 3 --lat 25 --lng 121 --height-m 5
      --title ok --country TW --creator-email a@b.co --right R --created-ms 0)
# The bogus flag carries no value. An earlier version wrote `$bogus X`, and the
# extra X became a second positional argument, which rgb1-pack rejects on its
# own -- so the check passed against the unfixed binary too and proved nothing.
# 該虛構旗標不帶值。先前版本寫成 `$bogus X`，多出來的 X 成為第二個位置參數，而
# rgb1-pack 本來就會拒絕——於是該檢查對未修正的執行檔同樣通過，什麼也證明不了。
for bogus in --titel --totally-bogus; do
  out="$TMP/reject_${bogus#--}.rgb1"
  rm -f "$out"
  if "$ST" "${BASE[@]}" "$bogus" -f "$out" "$RAW" >/dev/null 2>&1; then
    bad "rgb1-pack accepted unknown option $bogus"
  elif [ -e "$out" ]; then
    bad "rgb1-pack rejected $bogus but still wrote a container"
  else
    ok "rgb1-pack rejects unknown option $bogus and writes nothing"
  fi
done

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
