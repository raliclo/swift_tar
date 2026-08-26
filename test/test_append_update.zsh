#!/usr/bin/env zsh
# test_append_update.zsh
# Verify swift_tar's -r (append), -u (update), and --delete (in-place member
# removal — a feature BSD tar lacks) against the platform's standard tar. Every
# archive is validated by extracting it and diffing the tree against a
# reference, so container equivalence is checked by content, not byte layout.
# What that diff cannot see is asserted separately: section 4 checks that an
# appended symlink survives as a symlink, because diff -r follows links.
# 驗證 swift_tar 的 -r（追加）、-u（更新）與 --delete（就地移除項目——BSD tar
# 沒有的功能），並與系統 tar 對比。每個封存都以解出後的檔案樹與參考樹做 diff
# 比對，因此比的是內容等價，而非位元組佈局。該 diff 看不到的部分另行斷言：第 4 節
# 檢查追加的 symlink 是否仍以 symlink 形式存活，因為 diff -r 會跟隨連結。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE:h}"
if [ -z "${ST:-}" ]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
SYS_TAR="$(command -v tar)"

if [ ! -x "$ST" ]; then
  echo "error: build first (./compile_tar.zsh) — missing $ST" >&2
  exit 1
fi

# Keep the test output log in the script's own folder / 測試輸出 log 保存在腳本同一層資料夾
LOG="$HERE/test_append_update.log"
exec > >(tee "$LOG") 2>&1

# Temp working dir lives in the same folder, and is removed when done /
# 暫存工作資料夾建在同一層，測試結束即移除
TMP="$(mktemp -d "$HERE/.test_append_update.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT   # remove temp folder when the test finishes / 測試結束移除暫存資料夾

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"
echo "[Info] swift_tar: $ST"

pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
# desc dirA dirB → PASS iff the two trees carry the same names and the same file
# contents. This is not tree identity, and the earlier wording ("PASS iff
# identical trees") claimed more than the check delivers: diff -r compares
# content and follows symlinks, so mode, mtime, symlink target and hardlink
# sharing are all invisible to it. A symlink swapped for a regular file of the
# same content compares equal here. Section 4 asserts that case separately.
# desc dirA dirB → 兩棵樹的名稱與檔案內容相同才 PASS。這不是「樹完全相同」，而原本的
# 措辭（「兩棵樹相同才 PASS」）宣稱得比這道檢查實際做到的更多：diff -r 只比內容且會
# 跟隨 symlink，因此 mode、mtime、symlink 指向與 hardlink 共用關係它全部看不到。把
# symlink 換成同內容的一般檔案，在此仍會判定相同。第 4 節即為此另行斷言。
same_tree() {
  if diff -r "$2" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1 (trees differ)"; fi
}

SRC="$TMP/src"
mkdir -p "$SRC"
printf 'alpha\n' > "$SRC/a.txt"
printf 'bravo\n' > "$SRC/b.txt"

# ---------------------------------------------------------------------------
# 1) ADD (-r): create with a,b then append c; compare swift_tar vs system tar.
#    ADD（-r）：先建 a,b 再追加 c；swift_tar 與系統 tar 對比。
# ---------------------------------------------------------------------------
printf 'charlie\n' > "$SRC/c.txt"

"$ST"      -c -f "$TMP/sw.tar"  -C "$SRC" a.txt b.txt
"$ST"      -r -f "$TMP/sw.tar"  -C "$SRC" c.txt
"$SYS_TAR" -c -f "$TMP/ref.tar" -C "$SRC" a.txt b.txt
"$SYS_TAR" -r -f "$TMP/ref.tar" -C "$SRC" c.txt

mkdir -p "$TMP/x_sw_add" "$TMP/x_ref_add"
"$SYS_TAR" -x -f "$TMP/sw.tar"  -C "$TMP/x_sw_add"    # system tar reads swift_tar output (interop)
"$SYS_TAR" -x -f "$TMP/ref.tar" -C "$TMP/x_ref_add"
same_tree "ADD -r: swift_tar archive extracts identically to system tar" \
          "$TMP/x_sw_add" "$TMP/x_ref_add"

# entry set must contain exactly a,b,c / 項目集合須恰為 a,b,c
got="$("$ST" -t -f "$TMP/sw.tar" | tr -d '\r' | sort | tr '\n' ' ')"
[ "$got" = "a.txt b.txt c.txt " ] && ok "ADD -r: entry list is a,b,c" \
                                   || bad "ADD -r: entry list wrong: [$got]"

# ---------------------------------------------------------------------------
# 2) UPDATE (-u): a.txt newer + new d.txt appended; b,c unchanged are skipped.
#    UPDATE（-u）：a.txt 變新且新增 d.txt 會被追加；未變的 b,c 略過。
# ---------------------------------------------------------------------------
sleep 1
printf 'alpha-UPDATED\n' > "$SRC/a.txt"   # now newer than archived copy / 比封存副本新
printf 'delta\n'         > "$SRC/d.txt"   # brand new / 全新

# capture the pre-update entry count for the "skip unchanged" assertion
before="$("$ST" -t -f "$TMP/sw.tar" | wc -l | tr -d ' ')"
"$ST" -u -f "$TMP/sw.tar" -C "$SRC" a.txt b.txt c.txt d.txt
after="$("$ST" -t -f "$TMP/sw.tar" | wc -l | tr -d ' ')"

# exactly two new entries (a.txt re-added + d.txt); b,c must be skipped
[ "$((after - before))" -eq 2 ] && ok "UPDATE -u: only newer/new entries appended (b,c skipped)" \
                                 || bad "UPDATE -u: appended $((after - before)) entries, expected 2"

# newest-wins extraction: a.txt updated, b/c unchanged, d present
mkdir -p "$TMP/x_sw_upd"
"$ST" -x -f "$TMP/sw.tar" -C "$TMP/x_sw_upd"
same_tree "UPDATE -u: extracted tree matches current source (newest wins)" \
          "$TMP/x_sw_upd" "$SRC"

# ---------------------------------------------------------------------------
# 3) DELETE (--delete): swift_tar removes a member from the archive in place —
#    a capability BSD tar lacks. Verify the result by content and contrast with
#    the platform tar. / DELETE（--delete）：swift_tar 就地從封存移除項目——
#    BSD tar 沒有這功能。以內容驗證結果並與系統 tar 對比。
# ---------------------------------------------------------------------------
EXP="$TMP/expected_del"; mkdir -p "$EXP"     # expected tree = source minus b.txt / 期望樹＝來源減去 b.txt
cp "$SRC/a.txt" "$SRC/c.txt" "$SRC/d.txt" "$EXP/"

"$ST" -c      -f "$TMP/sw_del.tar" -C "$SRC" a.txt b.txt c.txt d.txt
"$ST" --delete -f "$TMP/sw_del.tar" b.txt    # in-place delete / 就地刪除

got="$("$ST" -t -f "$TMP/sw_del.tar" | tr -d '\r' | sort | tr '\n' ' ')"
[ "$got" = "a.txt c.txt d.txt " ] && ok "DELETE --delete: b.txt removed, a,c,d remain" \
                                  || bad "DELETE --delete: entry list wrong: [$got]"

# post-delete archive is still a valid tar (system tar extracts it) and its
# content matches the expected tree / 刪除後仍為合法 tar，內容與期望樹相符
mkdir -p "$TMP/x_sw_del"
"$SYS_TAR" -x -f "$TMP/sw_del.tar" -C "$TMP/x_sw_del"
same_tree "DELETE --delete: post-delete archive extracts to expected tree (interop)" \
          "$TMP/x_sw_del" "$EXP"

# contrast: does the platform tar even have --delete? / 對比：系統 tar 是否有 --delete？
"$SYS_TAR" -c -f "$TMP/ref_del.tar" -C "$SRC" a.txt b.txt c.txt d.txt
if "$SYS_TAR" --delete -f "$TMP/ref_del.tar" b.txt >/dev/null 2>&1; then
  # GNU tar present — it supports --delete; confirm swift_tar agrees
  mkdir -p "$TMP/x_ref_del"
  "$SYS_TAR" -x -f "$TMP/ref_del.tar" -C "$TMP/x_ref_del"
  same_tree "DELETE: swift_tar --delete agrees with GNU tar --delete" \
            "$TMP/x_sw_del" "$TMP/x_ref_del"
else
  ok "DELETE: system tar ($SYS_TAR) has no --delete — swift_tar-only capability"
fi

# ---------------------------------------------------------------------------
# 4) SYMLINK preservation through -r. Nothing above can see this: same_tree()
#    is the only tree check in this file and diff -r follows symlinks, so an
#    appended symlink that came back as a regular file would pass every
#    assertion here. Ask directly instead — is it still a link, and does it
#    still point where it did.
#    4）symlink 經 -r 後的保存性。上方沒有任何檢查看得到這件事：本檔唯一的樹比對是
#    same_tree()，而 diff -r 會跟隨 symlink，因此追加後變成一般檔案的 symlink 會通過
#    上面每一項斷言。所以直接問：它還是不是連結，指向有沒有變。
# ---------------------------------------------------------------------------
LNK="$TMP/lnk"; mkdir -p "$LNK"
printf 'echo\n' > "$LNK/target.txt"
# ln -s can succeed while producing a copy rather than a link (MSYS without
# winsymlinks), so the -L test decides whether this case is meaningful here.
# ln -s 可能「成功」卻產生副本而非連結（MSYS 未設 winsymlinks），故以 -L 判定本案例
# 在此環境是否有意義。
if ln -s target.txt "$LNK/link.txt" 2>/dev/null && [ -L "$LNK/link.txt" ]; then
  "$ST" -c -f "$TMP/sw_lnk.tar" -C "$LNK" target.txt
  "$ST" -r -f "$TMP/sw_lnk.tar" -C "$LNK" link.txt
  mkdir -p "$TMP/x_sw_lnk"
  "$ST" -x -f "$TMP/sw_lnk.tar" -C "$TMP/x_sw_lnk"
  # An `if` is required, not `[ -L … ] && …`: under `set -e` the && form exits
  # the whole script when the test is false — precisely the failure case.
  # 此處必須用 `if`，不能寫成 `[ -L … ] && …`：在 `set -e` 下，該寫法於測試為假時會
  # 讓整個腳本退出——而那正是要偵測的失敗情況。
  got_target=""
  if [ -L "$TMP/x_sw_lnk/link.txt" ]; then
    got_target="$(readlink "$TMP/x_sw_lnk/link.txt")"
  fi
  [ "$got_target" = "target.txt" ] \
    && ok "APPEND -r: an appended symlink stays a symlink, target intact" \
    || bad "APPEND -r: symlink preservation (link=[$got_target], expected [target.txt])"
else
  echo "SKIP: symlink preservation — cannot create symlinks here / 略過：此環境無法建立 symlink"
fi

# ---------------------------------------------------------------------------
echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
