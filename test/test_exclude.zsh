#!/usr/bin/env zsh
set -uo pipefail

# `--exclude <pattern>` 與 bsdtar 的相容性。
#
# 這個測試**不寫死預期值**，而是對每個樣式同時跑 bsdtar 與 swift_tar，比對兩者的成員
# 清單。理由：`--exclude` 的比對規則不是一條可以背下來的定義，而是若干互相牽動的細節，
# 而它們只有在與參照實作逐一對照時才會浮現。實作過程中八種樣式裡有一種不一致——
# `src/sub/*`——成因是 bsdtar 的目錄成員名帶結尾斜線，故 `*` 匹配到空字串而連目錄本身
# 一併排除。把預期值寫死的測試會把當時的錯誤行為一併釘住。
#
# Compatibility of `--exclude <pattern>` with bsdtar.
#
# This deliberately does not hardcode expectations: each pattern is run through both tars
# and their member lists compared. The matching rules are not one definition to memorise
# but several interacting details, and they only surface when checked against a reference.
# One shape of eight disagreed during implementation -- `src/sub/*` -- because bsdtar names
# directory members with a trailing slash, so `*` matches the empty string and the
# directory itself goes too. A test with baked-in expectations would have pinned the bug.

script_dir=${0:A:h}
root=${script_dir:h}
cd "$root"

tar=release/swift_tar
[[ $(uname -s) == *NT* ]] && tar=release/swift_tar.exe
[[ -x $tar ]] || { print -u2 -- "找不到 $tar；請先建置 / missing $tar"; exit 1 }
ST=$root/$tar

# 參照 tar 由實測選出，不由名稱假定：guest 的 /usr/bin/tar 是包在 BusyBox 外面、只支援
# 串流的前端，而本檔需要它寫出真正的封存並支援 --exclude。沿用 test_encrypt 與
# test_blind_findings 已確立的作法。
# The reference tar is probed rather than assumed by name, as in the other suites.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
REF=""
for cand in tar bsdtar gtar; do
  command -v $cand >/dev/null 2>&1 || continue
  mkdir -p "$work/probe/d"; print -- x > "$work/probe/d/f"
  if ( cd "$work/probe" && $cand cf ../p.tar --exclude 'nothing' d ) >/dev/null 2>&1 \
     && [[ -s "$work/p.tar" ]]; then
    REF=$cand; break
  fi
done
rm -rf "$work/probe" "$work/p.tar"
if [[ -z $REF ]]; then
  print -- "  skip 本環境沒有支援 --exclude 且能寫出封存的參照 tar"
  print -- "  skip no reference tar here that supports --exclude and can write an archive"
  print -- "通過 / PASS: exclude (skipped)"
  exit 0
fi

failures=0
check() {
  if [[ $1 == $2 ]]; then
    print -- "  ok   $3"
  else
    print -- "  FAIL $3"
    print -- "       $REF: $1"
    print -- "       swift_tar: $2"
    (( failures += 1 ))
  fi
}

mkdir -p "$work/src/sub"
print -- a > "$work/src/keep.txt"
print -- b > "$work/src/skip.log"
print -- c > "$work/src/sub/deep.log"

# 目錄成員的結尾斜線在兩邊的寫法不同，故一律去除後再比對——本檔比的是「哪些成員在」，
# 不是「名稱怎麼拼」。
# The trailing slash on directory members is spelled differently by the two tars, so it is
# stripped before comparing: this file is about which members are present, not how they
# are spelled.
members() {  # <tar 執行檔> <樣式>
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

print -- "--exclude 與 $REF 的相容性 / compatibility with $REF:"

# `*` 跨越 `/`、不含 `/` 的樣式比對每個路徑元件、目錄樣式連子樹一併排除——三條規則各由
# 下列樣式覆蓋，而非以文字斷言。
# Three rules -- `*` crossing `/`, componentwise matching for slash-free patterns, and a
# directory pattern taking its subtree -- each covered by a shape rather than by prose.
for pat in 'sub' '*.log' 'src/*.log' '*/deep.log' 'deep.log' 'src/sub/*' 'src/*' '*' 'nomatch'; do
  check "$(members $REF "$pat")" "$(members "$ST" "$pat")" "樣式 '$pat' / pattern '$pat'"
done

# 可重複給定。GNU tar 另接受 --exclude=PATTERN 的等號寫法，bsdtar 只有分開的形式，故
# 等號寫法單獨對照 swift_tar 自身的分開形式，而不要求參照 tar 也支援。
# Repeatable. The =PATTERN spelling is GNU's; bsdtar has only the separated form, so it is
# compared against swift_tar's own separated form rather than against the reference.
rm -f "$work/m1.tar" "$work/m2.tar"
( cd "$work" && $REF cf m1.tar --exclude '*.log' --exclude 'keep.txt' src ) >/dev/null 2>&1
( cd "$work" && "$ST" -c --exclude '*.log' --exclude 'keep.txt' -f m2.tar src ) >/dev/null 2>&1
check "$($REF tf "$work/m1.tar" 2>/dev/null | sed 's|/$||' | sort | tr '\n' ' ')" \
      "$("$ST" -t -f "$work/m2.tar" 2>/dev/null | sed 's|/$||' | sort | tr '\n' ' ')" \
      "可重複給定 / repeatable"

rm -f "$work/e1.tar" "$work/e2.tar"
( cd "$work" && "$ST" -c --exclude '*.log' -f e1.tar src ) >/dev/null 2>&1
( cd "$work" && "$ST" -c --exclude='*.log' -f e2.tar src ) >/dev/null 2>&1
check "$("$ST" -t -f "$work/e1.tar" 2>/dev/null | sort | tr '\n' ' ')" \
      "$("$ST" -t -f "$work/e2.tar" 2>/dev/null | sort | tr '\n' ' ')" \
      "--exclude=PATTERN 等同分開的形式 / =PATTERN equals the separated form"

# 被排除的目錄不得被走進去。這不只是「列表少了幾行」：它決定 --exclude 能否繞開一個讀不到
# 的子樹。2026-08-28 打包 CoreDevice 時，三個 ls 都讀不到的幽靈 .DS_Store 讓整次建立在
# 9,645/26,420 項處中止，而 --exclude 正是為此而加。若實作改成「先走訪再過濾」，本案例
# 會失敗而列表比對不會。
# An excluded directory must not be descended into. That is what lets --exclude step around
# an unreadable subtree, which is why it was added: three phantom .DS_Store entries that ls
# could not open aborted an entire create at 9,645 of 26,420 members. An implementation that
# walked first and filtered afterwards would pass the listing checks and fail this one.
mkdir -p "$work/src/nogo"
print -- x > "$work/src/nogo/secret"
chmod 000 "$work/src/nogo"
rm -f "$work/x.tar"
( cd "$work" && "$ST" -c --exclude 'nogo' -f x.tar src ) >"$work/x.out" 2>&1
x_rc=$?
chmod 755 "$work/src/nogo"
if (( x_rc == 0 )) && ! grep -q 'nogo' <( "$ST" -t -f "$work/x.tar" 2>/dev/null ); then
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
