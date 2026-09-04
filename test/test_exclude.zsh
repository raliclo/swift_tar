#!/usr/bin/env zsh
set -uo pipefail

# `--exclude <pattern>` 的相容性。
#
# 這個測試**不寫死預期值**，而是對每個樣式同時跑參照 tar 與 swift_tar，比對成員清單。
# 比對規則不是一條可以背下來的定義，而是若干互相牽動的細節，只有與參照實作逐一對照才會
# 浮現。實作過程中八種樣式裡有一種不一致（`src/sub/*`），成因是 bsdtar 的目錄成員名帶
# 結尾斜線，故 `*` 匹配到空字串而連目錄本身一併排除。把預期值寫死的測試會把當時的錯誤
# 行為一併釘住。
#
# **參照實作彼此並不一致**，這是本檔最重要的一件事。bsdtar 3.5.3 與 GNU tar 1.35 在
# 兩個樣式上分歧：
#
#     src/sub/*   bsdtar 連 src/sub 一併排除；GNU 保留該目錄、只排除其內容
#     src/*       bsdtar 連 src 一併排除（結果為空）；GNU 保留 src
#
# swift_tar 跟隨 bsdtar，因為本工具在 macOS 上的參照一向是它（本 repo 各處的互通測試
# 皆以 bsdtar 為對照）。此處把該選擇當成斷言釘住，而非略過那兩個樣式——略過會讓日後
# 任何一邊的行為改變都無聲通過。
#
# Compatibility of `--exclude <pattern>`.
#
# Expectations are not hardcoded: each pattern runs through a reference tar and through
# swift_tar, and the member lists are compared. The rules are several interacting details
# rather than one definition, and they only surface against a reference.
#
# The references disagree with each other, which is the point of this file. bsdtar 3.5.3
# and GNU tar 1.35 differ on two shapes: bsdtar's directory members carry a trailing
# slash, so a pattern ending in `/*` takes the directory too, while GNU keeps it. swift_tar
# follows bsdtar, and that choice is asserted here rather than skipped -- skipping would let
# a later change on either side pass in silence.
#
# 平台偵測以 `--version` 的輸出為準，不以名稱假定：macOS 的 `tar` 是 bsdtar，Linux 的
# `tar` 是 GNU，而 macOS 上的 `gtar` 才是 GNU。以名稱猜測會在其中一個平台上比對到錯的
# 實作，且不會有任何東西回報。
# Platform detection reads `--version` rather than assuming by name: `tar` is bsdtar on
# macOS and GNU on Linux, while `gtar` is GNU on macOS. Guessing by name compares against
# the wrong implementation on one platform and nothing reports it.

script_dir=${0:A:h}
root=${script_dir:h}
cd "$root"

tar_bin=release/swift_tar
[[ $(uname -s) == *NT* ]] && tar_bin=release/swift_tar.exe
[[ -x $tar_bin ]] || { print -u2 -- "找不到 $tar_bin；請先建置 / missing $tar_bin"; exit 1 }
ST=$root/$tar_bin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 分類每個候選者：能寫出封存、支援 --exclude，且由 --version 判定家族。
# Classify each candidate: can write an archive, supports --exclude, family from --version.
# Windows 上的 bsdtar 沒有一個叫得出來的名字。系統自帶的是 C:\Windows\System32\tar.exe，
# 而 Git Bash 的 PATH 上 `tar` 會先解析到 scoop／MSYS 的 GNU tar，`bsdtar` 則根本不是一個
# 指令。於是這支測試在 Windows 上一直是 bsdtar=none：分歧那兩個樣式被跳過，而檔頭宣告
# 「swift_tar 跟隨 bsdtar」的那個選擇，在唯一同時擁有 bsdtar 與 swift_tar 的平台上從未被
# 驗證過。加入絕對路徑而非再加一個名字——問題正是它沒有名字。
# On Windows bsdtar has no name to look up. The system one is C:\Windows\System32\tar.exe,
# while `tar` on Git Bash's PATH resolves to scoop/MSYS GNU tar first and `bsdtar` is not a
# command at all. So this file ran with bsdtar=none there: the divergent shapes were skipped,
# and the choice the header states -- that swift_tar follows bsdtar -- went unverified on the
# one platform that has both bsdtar and swift_tar. An absolute path rather than another name,
# because having no name is the problem.
BSD=""; GNU=""
for cand in tar bsdtar gtar gnutar /c/Windows/System32/tar.exe; do
  command -v $cand >/dev/null 2>&1 || continue
  rm -rf "$work/probe" "$work/p.tar"; mkdir -p "$work/probe/d"; print -- x > "$work/probe/d/f"
  ( cd "$work/probe" && $cand cf ../p.tar --exclude 'nothing' d ) >/dev/null 2>&1 || continue
  [[ -s "$work/p.tar" ]] || continue
  local_ver=$($cand --version 2>&1 | head -1)
  case $local_ver in
    *"GNU tar"*) [[ -z $GNU ]] && GNU=$cand ;;
    *bsdtar*)    [[ -z $BSD ]] && BSD=$cand ;;
  esac
done
rm -rf "$work/probe" "$work/p.tar"

print -- "參照實作 / references: bsdtar=${BSD:-none}  GNU=${GNU:-none}"
if [[ -z $BSD && -z $GNU ]]; then
  print -- "  skip 本環境沒有可用的參照 tar / no usable reference tar here"
  print -- "通過 / PASS: exclude (skipped)"
  exit 0
fi

failures=0
# printf 而非 print：`print` 會解釋逸出序列，於是樣式 `\*.log` 的標籤印成 `*.log`，與清單裡
# 真正的 `*.log` 那一項完全同名。兩個不同的檢查頂著同一個標籤，失敗時無從分辨是哪一個——
# 而逸出樣式正是最需要看清楚的那一類。%s 的引數不受格式字串影響，反斜線原樣通過。
# printf, not print: `print` interprets escape sequences, so the pattern `\*.log` printed its
# label as `*.log` -- identical to the genuine `*.log` entry in the same list. Two different
# checks under one label leave a failure unattributable, and escaped patterns are exactly the
# ones that need to be legible. A %s argument is untouched by the format string.
check() {
  if [[ $1 == $2 ]]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n' "$3"
    printf '       期望 / expected : %s\n' "$1"
    printf '       實際 / got      : %s\n' "$2"
    (( failures += 1 ))
  fi
}

mkdir -p "$work/src/sub"
print -- a > "$work/src/keep.txt"
print -- b > "$work/src/skip.log"
print -- c > "$work/src/sub/deep.log"
# 這三個是為了字元類、範圍與逸出而加的：單靠上面三個檔，`[a-z].log`、`[!…]` 與 `\*` 都
# 會因為「沒有東西可命中」而在任何實作上都得到相同結果，那樣的比對通過與否毫無資訊。
# 名稱只用 Windows 也合法的字元——`*` 與 `?` 不能出現在檔名裡，故僅出現在樣式側。
# These three exist for the character-class, range and escape patterns: with only the three
# above, `[a-z].log`, `[!...]` and `\*` would match nothing in every implementation, and a
# comparison that passes for that reason carries no information. The names use only
# characters Windows allows -- `*` and `?` cannot appear in a filename, so they appear on
# the pattern side alone.
print -- d > "$work/src/a.log"
print -- e > "$work/src/note-.txt"
print -- f > "$work/src/br[ack].txt"

# 目錄成員的結尾斜線在各實作間拼法不同，故一律去除後再比對——本檔比的是「哪些成員在」，
# 不是「名稱怎麼拼」。
# The trailing slash is spelled differently by each implementation, so it is stripped: this
# file compares which members are present, not how they are spelled.
members() {  # <tar> <樣式>
  local t=$1 pat=$2 out
  rm -f "$work/a.tar"
  if [[ $t == "$ST" ]]; then
    ( cd "$work" && "$ST" -c --exclude "$pat" -f a.tar src ) >/dev/null 2>&1
    out=$( "$ST" -t -f "$work/a.tar" 2>/dev/null )
  else
    ( cd "$work" && $t cf a.tar --exclude "$pat" src ) >/dev/null 2>&1
    out=$( $t tf "$work/a.tar" 2>/dev/null )
  fi
  print -- "${out}" | sed 's|/$||' | sort | tr '\n' ' '
}

# 兩個參照實作一致的樣式：swift_tar 必須與兩者皆同。
# Shapes the references agree on: swift_tar must match both.
# 後 15 個涵蓋 `?`、字元類、範圍、`!`／`^` 反向、`[]]`、`[a-]`、未閉合的 `[`，以及反斜線
# 逸出。加進來的原因是這些規則先前一條也沒被測到：原本的七個樣式只用到 `*` 與字面字元。
#
# 那個空白在 Windows 上特別重。POSIX 端 `--exclude` 直接呼叫 `fnmatch`，Windows 端沒有
# 這個函式，走的是 `#if os(Windows)` 內另一份實作——也就是說，唯一沒有參照可比的那份
# 實作，恰好是唯一沒被測到的那份。實測後兩邊皆一致（Windows 對 bsdtar 15/15，Linux 對
# GNU tar 15/15），所以這裡釘住的是量到的結果，不是假設。
#
# The last 15 cover `?`, character classes, ranges, `!`/`^` negation, `[]]`, `[a-]`, an
# unterminated `[`, and backslash escapes. They are here because not one of those rules was
# exercised before: the original seven use only `*` and literal characters.
#
# That gap mattered most on Windows. On POSIX `--exclude` calls `fnmatch` directly; Windows
# has no such function and runs a separate implementation under `#if os(Windows)` -- so the
# one implementation with nothing to compare against was also the one nothing tested. Both
# platforms were measured before these were added (Windows 15/15 against bsdtar, Linux 15/15
# against GNU tar), so what is pinned here is a measurement, not an assumption.
AGREED=('sub' '*.log' 'src/*.log' '*/deep.log' 'deep.log' '*' 'nomatch'
        '?.log' '????.log' '[ad]*.log' '[a-z].log' '[!a-z]*.log' '[^a-z]*.log'
        'br[ack].txt' 'br[]].txt' '[.txt' 'br[a-c]ck].txt' '*[.]log' '[a-]*'
        '\*.log' 'note\-.txt' '*.???')
# 兩者分歧的樣式：swift_tar 必須與 bsdtar 同，且必須與 GNU 不同——後者同樣是斷言，
# 因為若 GNU 哪天改成與 bsdtar 一致，這個註解與選擇就該重新檢視。
# Shapes they disagree on: swift_tar must match bsdtar and must differ from GNU. The second
# half is asserted too: if GNU ever aligns with bsdtar, this choice deserves revisiting.
DIVERGENT=('src/sub/*' 'src/*')

print -- ""
print -- "兩參照一致的樣式 / shapes the references agree on:"
for pat in $AGREED; do
  s=$(members "$ST" "$pat")
  [[ -n $BSD ]] && check "$(members $BSD "$pat")" "$s" "'$pat' 與 bsdtar 一致 / matches bsdtar"
  [[ -n $GNU ]] && check "$(members $GNU "$pat")" "$s" "'$pat' 與 GNU tar 一致 / matches GNU tar"
done

if [[ -n $BSD && -n $GNU ]]; then
  print -- ""
  print -- "兩參照分歧的樣式 / shapes the references disagree on:"
  for pat in $DIVERGENT; do
    b=$(members $BSD "$pat"); g=$(members $GNU "$pat"); s=$(members "$ST" "$pat")
    if [[ $b == $g ]]; then
      print -- "  FAIL '$pat' 預期 bsdtar 與 GNU 分歧，實際相同——此處的選擇需重新檢視"
      print -- "       '$pat' expected the references to differ; they now agree, so revisit"
      (( failures += 1 ))
      continue
    fi
    check "$b" "$s" "'$pat' 跟隨 bsdtar / follows bsdtar"
    if [[ $s == $g ]]; then
      print -- "  FAIL '$pat' 同時等於 GNU 的結果，分歧未被保留"
      (( failures += 1 ))
    else
      print -- "  ok   '$pat' 與 GNU 不同，如預期 / differs from GNU as expected"
    fi
  done
else
  print -- ""
  print -- "  skip 只有一個參照實作，分歧項無從比對 / only one reference; divergence untested"
fi

print -- ""
print -- "其他 / other:"

# 可重複給定。以 bsdtar 為準；只有 GNU 時亦可比對，兩者在此無分歧。
# Repeatable. Checked against whichever reference exists; they do not diverge here.
REF=${BSD:-$GNU}
rm -f "$work/m1.tar" "$work/m2.tar"
( cd "$work" && $REF cf m1.tar --exclude '*.log' --exclude 'keep.txt' src ) >/dev/null 2>&1
( cd "$work" && "$ST" -c --exclude '*.log' --exclude 'keep.txt' -f m2.tar src ) >/dev/null 2>&1
check "$($REF tf "$work/m1.tar" 2>/dev/null | sed 's|/$||' | sort | tr '\n' ' ')" \
      "$("$ST" -t -f "$work/m2.tar" 2>/dev/null | sed 's|/$||' | sort | tr '\n' ' ')" \
      "可重複給定 / repeatable"

# --exclude=PATTERN 是 GNU 的寫法；bsdtar 只有分開的形式，故此處對照 swift_tar 自身的
# 分開形式，不要求參照 tar 也支援。
# =PATTERN is GNU's spelling; bsdtar has only the separated form, so this compares
# swift_tar against itself rather than requiring it of the reference.
rm -f "$work/e1.tar" "$work/e2.tar"
( cd "$work" && "$ST" -c --exclude '*.log' -f e1.tar src ) >/dev/null 2>&1
( cd "$work" && "$ST" -c --exclude='*.log' -f e2.tar src ) >/dev/null 2>&1
check "$("$ST" -t -f "$work/e1.tar" 2>/dev/null | sort | tr '\n' ' ')" \
      "$("$ST" -t -f "$work/e2.tar" 2>/dev/null | sort | tr '\n' ' ')" \
      "--exclude=PATTERN 等同分開的形式 / =PATTERN equals the separated form"

# 被排除的目錄不得被走進去。這不只是「列表少了幾行」：它決定 --exclude 能否繞開一個讀不到
# 的子樹。2026-08-28 打包 CoreDevice 時，三個 ls 都開不了的幽靈 .DS_Store 讓整次建立在
# 9,645/26,420 項處中止，而 --exclude 正是為此而加。若實作改成「先走訪再過濾」，本案例
# 會失敗而上方的列表比對不會。
# An excluded directory must not be descended into. That is what lets --exclude step around
# an unreadable subtree, which is why it exists. An implementation that walked first and
# filtered afterwards would pass every listing check above and fail this one.
mkdir -p "$work/src/nogo"; print -- x > "$work/src/nogo/secret"
chmod 000 "$work/src/nogo"
rm -f "$work/x.tar"
( cd "$work" && "$ST" -c --exclude 'nogo' -f x.tar src ) >"$work/x.out" 2>&1
x_rc=$?
chmod 755 "$work/src/nogo"
if (( x_rc == 0 )) && ! "$ST" -t -f "$work/x.tar" 2>/dev/null | grep -q 'nogo'; then
  print -- "  ok   被排除的目錄不會被走進去 / an excluded directory is not descended into"
else
  print -- "  FAIL 被排除的目錄仍被走進去 / an excluded directory was still descended into"
  print -- "       rc=$x_rc"
  sed 's/^/       /' "$work/x.out"
  (( failures += 1 ))
fi

print -- ""
if (( failures == 0 )); then
  print -- "通過 / PASS: exclude"
else
  print -u2 -- "失敗 / FAIL: $failures check(s)"
fi
exit $(( failures != 0 ))
