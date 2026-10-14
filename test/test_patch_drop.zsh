#!/usr/bin/env zsh
# test_patch_drop.zsh -- patch/apply_patches.zsh on a source drop: no .git, state read from
# the patch text.
# test_patch_drop.zsh -- 在原始碼包上執行 patch/apply_patches.zsh：沒有 .git，狀態由 patch
# 的文字讀出。
#
#   zsh test/test_patch_drop.zsh          run / 執行
#   zsh test/test_patch_drop.zsh --help   print this synopsis and exit / 印出說明後結束
#
# Why: a drop is built where there may be no git (the Linux VM's guest), so the script must
# tell patched sources from unpatched ones by itself. The first attempt asked
# `patch -R --dry-run`, and on macOS that answered "applied" for untouched sources -- Apple's
# patch 2.0 applies a reversed patch forward and exits 0 -- after which --revert rewrote
# them (2026-10-13). Each state is checked here on a copy of the files the patches touch,
# and the copy is compared byte for byte with the submodule after the round trip.
# 為什麼：原始碼包可能在沒有 git 的地方建置（Linux VM 的 guest），腳本必須自己分辨 patch 過
# 與沒 patch 過的原始碼。第一版去問 `patch -R --dry-run`，而它在 macOS 上對沒動過的原始碼
# 回答「已套用」——Apple 的 patch 2.0 會把反向 patch 正向套用並以 0 結束——接著 --revert 把
# 檔案改寫了（2026-10-13）。這裡對 patch 所碰到的檔案的副本逐一檢查每種狀態，並在來回一趟
# 之後與 submodule 逐位元組比較。
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,8p' "${0:A}" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT="${0:A:h:h}"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

command -v patch >/dev/null 2>&1 || { echo "SKIP: no patch command here"; exit 0; }
[ -f "$ROOT/libarchive/CMakeLists.txt" ] || { echo "SKIP: libarchive/ is not checked out"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/patch"
cp -R "$ROOT/patch/." "$TMP/patch/"

# The files the patches name, copied without .git. / patch 指名的檔案，複製時不帶 .git。
files=()
for p in "$ROOT"/patch/libarchive/*.patch(N); do
  while IFS= read -r line; do
    [[ $line == '+++ b/'* ]] && files+=("${line#+++ b/}")
  done < "$p"
done
files=(${(u)files})
(( ${#files} )) || { echo "SKIP: no libarchive patches"; exit 0; }
# A shape busybox's patch cannot apply, read from the patch text so that it is caught on a
# machine that has another patch(1). apply_patches.zsh passes -N, and with -N busybox takes a
# hunk for already applied the moment the file line that follows an insertion equals one of
# the lines being inserted. 0003 first put a function whose definition starts with a line
# holding just `int` in front of another such line: it applied on macOS, and the Linux
# guest, whose patch is busybox's, reported "Hunk 2 FAILED" and built nothing (2026-10-14).
# busybox 的 patch 套不上的一種形狀，直接從 patch 的文字判斷，這樣在裝著別種 patch(1) 的機器上
# 也抓得到。apply_patches.zsh 會帶 -N，而 busybox 在 -N 之下，只要插入點之後的那一行與被插入的
# 任何一行相同，就把該 hunk 當成已經套用。0003 起初把一個「定義以單獨一行 `int` 開頭」的函式放在
# 另一個同樣開頭的函式之前：macOS 上套得上，而 patch 是 busybox 版的 Linux guest 回報
# 「Hunk 2 FAILED」，什麼都沒建出來（2026-10-14）。
for p in "$ROOT"/patch/libarchive/*.patch(N); do
  clash=$(awk '/^@@/ { body = 1; split("", run); inrun = 0; next }
               !body { next }
               /^diff / { body = 0; next }
               /^\+/ { run[substr($0, 2)] = 1; inrun = 1; next }
               { if (inrun && (substr($0, 2) in run)) print "[" substr($0, 2) "]"; split("", run); inrun = 0 }' "$p")
  [ -z "$clash" ] && ok "${p:t}: no inserted line equals the line after the insertion" \
    || bad "${p:t}: no inserted line equals the line after the insertion (${clash//$'\n'/ })"
done

# The submodule must be unpatched for the copy to start unpatched. / submodule 須為未 patch 狀態。
# --check exits 1 when a patch is missing, which is the state wanted here; under pipefail
# that would fail the pipeline, so the output is taken first.
# 有 patch 未套用時 --check 以 1 結束，而那正是這裡要的狀態；在 pipefail 下那會讓整條
# pipeline 失敗，所以先把輸出取出來。
sub_state=$( cd "$ROOT" && ./patch/apply_patches.zsh --check 2>&1 || true )
if [ "$(print -r -- "$sub_state" | grep -c '未套用')" != "$(print -l "$ROOT"/patch/libarchive/*.patch(N) | wc -l | tr -d ' ')" ]; then
  echo "SKIP: libarchive/ is not in its unpatched state (a build is running, or this is a source drop left patched after one)"
  exit 0
fi
for f in $files; do mkdir -p "$TMP/libarchive/${f:h}"; cp "$ROOT/libarchive/$f" "$TMP/libarchive/$f"; done

run() { ( cd "$TMP" && ./patch/apply_patches.zsh "$@" ) > "$TMP/out" 2>&1; }
npatch=$(print -l "$ROOT"/patch/libarchive/*.patch(N) | wc -l | tr -d ' ')

rc=0; run --check || rc=$?
[ "$rc" = 1 ] && ok "unpatched drop: --check exits 1" || bad "unpatched drop: --check exits 1 (got $rc)"
[ "$(grep -c '未套用' "$TMP/out")" = "$npatch" ] && ok "unpatched drop: every patch reported not applied" \
  || bad "unpatched drop: every patch reported not applied ($(tr '\n' '|' < "$TMP/out"))"
unchanged=1
for f in $files; do cmp -s "$TMP/libarchive/$f" "$ROOT/libarchive/$f" || unchanged=0; done
(( unchanged )) && ok "--check changes nothing" || bad "--check changes nothing"

rc=0; run || rc=$?
[ "$rc" = 0 ] && ok "apply exits 0" || bad "apply exits 0 (got $rc; $(tr '\n' '|' < "$TMP/out"))"
rc=0; run --check || rc=$?
[ "$rc" = 0 ] && ok "patched drop: --check exits 0" || bad "patched drop: --check exits 0 (got $rc)"
changed=0
for f in $files; do cmp -s "$TMP/libarchive/$f" "$ROOT/libarchive/$f" || changed=$((changed + 1)); done
[ "$changed" = "${#files}" ] && ok "apply changed every file the patches name" \
  || bad "apply changed every file the patches name ($changed of ${#files})"

rc=0; run --revert || rc=$?
[ "$rc" = 0 ] && ok "revert exits 0" || bad "revert exits 0 (got $rc)"
same=1
for f in $files; do cmp -s "$TMP/libarchive/$f" "$ROOT/libarchive/$f" || same=0; done
(( same )) && ok "after the round trip the drop is byte-identical to the submodule" \
  || bad "after the round trip the drop is byte-identical to the submodule"

# Neither state: one line a patch adds is present and one it removes is gone.
# 兩者皆非：patch 新增的某一行在、移除的某一行不在。
f=${files[1]}
# The last patch that removes a line: one that only adds (0003) has no line to take away.
# 取最後一份有移除行的 patch：只新增的 patch（0003）沒有可以拿掉的行。
p=("$ROOT"/patch/libarchive/*.patch(N))
last=""
for candidate in "${(@Oa)p}"; do
  if grep -q -E '^-[^-]' "$candidate"; then last=$candidate; break; fi
done
gone=$(grep -m1 -E '^-[^-]' "$last" | cut -c2-)
target="$TMP/libarchive/${$(grep -m1 '^+++ b/' "$last")#+++ b/}"
grep -vFx -- "$gone" "$target" > "$target.new" && mv "$target.new" "$target"
rc=0; run --check || rc=$?
grep -q 'neither applies nor reverses' "$TMP/out" && [ "$rc" = 1 ] \
  && ok "a file matching neither state is reported stale, exit 1" \
  || bad "a file matching neither state is reported stale, exit 1 (rc $rc; $(tr '\n' '|' < "$TMP/out"))"

# A patch whose only added line is already somewhere else in the file. Until 2026-10-14 the
# state was read one line at a time anywhere in the file, so this was "applied" on sources
# nobody had touched. In a drop of its own, with one made-up patch, so that nothing above
# is counted twice.
# 一份 patch，它唯一新增的那一行本來就在檔案的別處。2026-10-14 之前，狀態是逐行在檔案任何
# 位置找出來的，所以對沒人動過的原始碼，這會是「已套用」。放在自己的一份原始碼包裡，只帶一份
# 編出來的 patch，免得上面的東西被重複計數。
DUP="$TMP/dup"
mkdir -p "$DUP/patch/demo" "$DUP/demo"
cp "$ROOT/patch/apply_patches.zsh" "$DUP/patch/"
print -l 'int first(void) {' '    return 1;' '}' 'int second(void) {' '    int ret;' '    return 2;' '}' > "$DUP/demo/a.c"
cp "$DUP/demo/a.c" "$DUP/a.c.orig"
print -rl -- '--- a/a.c' '+++ b/a.c' '@@ -1,3 +1,4 @@' ' int first(void) {' '+    int ret;' '     return 1;' ' }' \
  > "$DUP/patch/demo/0001-dup.patch"
drun() { ( cd "$DUP" && ./patch/apply_patches.zsh "$@" ) > "$DUP/out" 2>&1; }
rc=0; drun --check || rc=$?
grep -q '未套用' "$DUP/out" && [ "$rc" = 1 ] \
  && ok "a patch adding a line found elsewhere in the file is reported not applied" \
  || bad "a patch adding a line found elsewhere in the file is reported not applied (rc $rc; $(tr '\n' '|' < "$DUP/out"))"
rc=0; drun || rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'int ret;' "$DUP/demo/a.c")" = 2 ] \
  && ok "and applying it changes the file" \
  || bad "and applying it changes the file (rc $rc; $(tr '\n' '|' < "$DUP/out"))"
rc=0; drun --check || rc=$?
[ "$rc" = 0 ] && ok "after which --check exits 0" || bad "after which --check exits 0 (got $rc)"

# A patch that cannot be applied says why. The reason used to be thrown away, leaving
# "failed to apply" and nothing to act on. The file is put back and made unwritable along
# with its directory: the text still reads as not applied, and `patch` cannot write.
# 套不上的 patch 要說出原因。原因原本被丟掉，只剩「套用失敗」而沒有可以著手的東西。把檔案放
# 回去，連同它的目錄設成不可寫：文字讀起來仍是未套用，而 `patch` 寫不進去。
if [ "$(id -u)" != 0 ]; then
  cp "$DUP/a.c.orig" "$DUP/demo/a.c"
  chmod 444 "$DUP/demo/a.c"; chmod 555 "$DUP/demo"
  rc=0; drun || rc=$?
  chmod 755 "$DUP/demo"; chmod 644 "$DUP/demo/a.c"
  said=$(grep -v -e '^  ' -e '^$' -e '^已套用' "$DUP/out" || true)
  [ "$rc" = 1 ] && grep -q 'failed to apply' "$DUP/out" && [ -n "$said" ] \
    && ok "a patch that fails to apply shows what patch said" \
    || bad "a patch that fails to apply shows what patch said (rc $rc; $(tr '\n' '|' < "$DUP/out"))"
else
  echo "SKIP: failed-apply case (root can write anywhere)"
fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" = 0 ]
