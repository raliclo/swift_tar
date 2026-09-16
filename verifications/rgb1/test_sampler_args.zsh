#!/usr/bin/env zsh
# test_sampler_args.zsh
# Pin rgb1_sampler's argument guards. Only the guards -- sampling itself needs a
# video file and ffmpeg, and is exercised by make_consecutive_corpus.zsh.
# 釘住 rgb1_sampler 的參數守衛。只測守衛——取樣本身需要影片與 ffmpeg，由
# make_consecutive_corpus.zsh 涵蓋。
#
# 為什麼這支測試存在：`--clean-only` 是破壞性的，而它的目標目錄有一個**預設值**。
# 該檔案的註解記載語料曾因此被誤刪一次，而修正之後仍有兩條路通往同一個結局：
#
#   `--clean-only --out`（`--out` 沒帶值）→ 舊版靜默退回 ./sample 並清掉它
#   `--clean-only --ou DIR`（打錯的選項）  → 舊版丟掉 `--ou`，DIR 變成位置引數
#
# 兩者都以離開碼 0 結束，畫面上看起來像正常完成。這正是「不會失敗的測試擋不住」的
# 那一類，所以此處斷言的是**目錄內容**，不只是離開碼。
#
# Why this exists: `--clean-only` is destructive and its target has a default. The
# source file records that the corpus was deleted once this way, and after that fix
# two routes still led to the same place -- a valueless `--out` and a mistyped long
# option, both exiting 0. The assertions check directory contents, not just status.
#
#   ./verifications/rgb1/test_sampler_args.zsh
#   ./verifications/rgb1/test_sampler_args.zsh --help
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,26p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE=${script_path:h}
ROOT=${HERE:h:h}
cd "$ROOT"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sampler-args.XXXXXX")
BIN="$TMP/rgb1_sampler"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

command -v swiftc >/dev/null 2>&1 || { print -- "SKIP: no swiftc"; exit 0 }
# No `2>/dev/null`: CLAUDE.md forbids hiding build output, and here it hid the one thing
# that explains a failed build -- the compiler's own message -- behind "cannot build".
# Measured 2026-09-17 with it removed: WSL prints nothing, and Windows prints only
# link.exe's "Creating library ... .lib" line, so nothing was being hidden but noise and
# the next real error.
# 不加 `2>/dev/null`：CLAUDE.md 禁止藏起建置輸出，而此處藏起的正是唯一能解釋建置失敗的
# 東西——編譯器自己的訊息——只留下「無法建置」。2026-09-17 拿掉後實測：WSL 不印任何東西，
# Windows 只印 link.exe 的「Creating library ... .lib」那一行，所以被藏起的只有雜訊，
# 以及下一個真正的錯誤。
swiftc -O -o "$BIN" verifications/rgb1/rgb1_sampler.swift rgb1.swift \
  || { print -ru2 -- "error: cannot build rgb1_sampler / 無法建置"; exit 1 }

pass=0; fail=0
ok()  { print -- "PASS: $1"; pass=$(( pass + 1 )) }
bad() { print -- "FAIL: $1"; fail=$(( fail + 1 )) }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (want '$2', got '$3')" }

# 每個案例都重建一個帶檔案的 sample/，因為要斷言的正是「它有沒有被動過」。
# Each case rebuilds a populated sample/, because what is asserted is whether it survived.
seed() {
  rm -rf "$TMP/w"; mkdir -p "$TMP/w/sample" "$TMP/w/other"
  print -r -- a > "$TMP/w/sample/one.rgb1"
  print -r -- b > "$TMP/w/sample/two.rgb1"
  print -r -- c > "$TMP/w/other/three.rgb1"
}
count() { ls "$1" 2>/dev/null | wc -l | tr -d ' ' }

# --- 1. --out with no value must not fall back to the default and delete it ---
seed
rc=0; ( cd "$TMP/w" && "$BIN" --clean-only --out ) >/dev/null 2>&1 || rc=$?
eq "--out with no value is refused"              "1" "$rc"
eq "--out with no value leaves sample/ intact"   "2" "$(count "$TMP/w/sample")"

# --- 2. an unrecognised long option must be refused, not silently dropped ---
seed
rc=0; ( cd "$TMP/w" && "$BIN" --clean-only --ou other ) >/dev/null 2>&1 || rc=$?
eq "unknown long option is refused"              "1" "$rc"
eq "unknown long option leaves sample/ intact"   "2" "$(count "$TMP/w/sample")"
eq "unknown long option leaves other/ intact"    "1" "$(count "$TMP/w/other")"

# --- 3. a mistyped --clean-only must not be accepted as a no-op either ---
# 這一項防的是反向：打錯的旗標被吞掉之後，保護就不存在了，而使用者以為有。
# The reverse hazard: a swallowed typo means the protection is simply absent.
seed
rc=0; ( cd "$TMP/w" && "$BIN" --clean-onlyy other ) >/dev/null 2>&1 || rc=$?
eq "mistyped --clean-only is refused"            "1" "$rc"

# --- 4. the ordinary path still works, and touches only what was named ---
seed
rc=0; ( cd "$TMP/w" && "$BIN" --clean-only --out other ) >/dev/null 2>&1 || rc=$?
eq "--out DIR is accepted"                       "0" "$rc"
eq "--out DIR cleans the named directory"        "0" "$(count "$TMP/w/other")"
eq "--out DIR leaves the default alone"          "2" "$(count "$TMP/w/sample")"

print -- "-----------------------------------------"
print -- "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
