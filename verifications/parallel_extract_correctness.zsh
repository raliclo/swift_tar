#!/usr/bin/env zsh
# Correctness of the parallel extraction write path.
#
#   ./verifications/parallel_extract_correctness.zsh [output-report]
#
# The writer pool turns extraction from a strictly ordered sequence into
# concurrent workers plus explicit barriers. Everything that can break is an
# ORDERING property, and ordering bugs do not fail every run -- they fail the
# unlucky one. So each case runs at several -n values and repeats.
#
# 平行解壓寫檔路徑的正確性。寫入池把解壓從嚴格有序的序列變成「並行 worker
# ＋明確屏障」。會壞掉的東西全都是「順序性質」，而順序錯誤不會每次都失敗——
# 它只在運氣不好的那次失敗。因此每個案例都以多個 -n 值重複執行。
#
# WHAT EACH CASE GUARDS
#
#   modes      the pool applies mode itself now (fchmod on the write fd). If
#              that were dropped, files would silently come out umask-default.
#   mtime      applied by the worker via futimens, not by the main thread.
#   symlink    a queued write to the same name must land before removeItem,
#              or the worker recreates the file over the symlink.
#   hardlink   link(2) needs the target to exist; it may still be queued.
#   duplicate  tar overwrite semantics: the LAST entry must win, which is not
#              automatic once writes are concurrent.
#   mixed      files above smallFileMax take the inline path; the two paths
#              must interleave correctly.
#   failure    a worker error must surface as a non-zero exit, not be lost.
#
# 各案例守護的性質：modes（權限現由池以 fchmod 套用，漏掉會靜默變成 umask 預設）、
# mtime（由 worker 以 futimens 設定）、symlink（同名佇列寫入須先落地）、
# hardlink（link(2) 需目標已存在）、duplicate（tar 覆蓋語意：最後一筆勝出）、
# mixed（超過 smallFileMax 走 inline 路徑，兩條路徑須正確交錯）、
# failure（worker 的錯誤必須以非零結束碼浮現，不得遺失）。

emulate -L zsh
setopt no_unset pipe_fail

HERE=${0:A:h}
ST=${SWIFT_TAR:-$HERE/../release/swift_tar}
BSDTAR=${BSDTAR:-/usr/bin/tar}
NVALUES=(${=SWIFT_TAR_N:-1 2 8 16})
REPEATS=${REPEATS:-3}

[[ -x $ST ]] || { print -ru2 -- "no swift_tar at $ST (set SWIFT_TAR=)"; exit 1 }

B=$(mktemp -d "${TMPDIR:-/tmp}/swifttar-pc.XXXXXX")
trap 'rm -rf $B' EXIT INT TERM

REPORT=${1:-$HERE/parallel_extract_correctness_output.txt}

typeset -a OUT NAMES RES
say()   { print -r -- "$1"; OUT+=("$1") }
check() { NAMES+=("$1"); RES+=($2)
          say "  [$([[ $2 == 1 ]] && print PASS || print FAIL)] $1${3:+ -- $3}" }

say "# swift_tar parallel extraction: correctness"
say "date      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "swift_tar : $($ST --version 2>&1 | head -1)"
say "host      : $(uname -srm)"
say "-n values : $NVALUES   repeats: $REPEATS"
say "umask     : $(umask)   (modes must survive it -- see the modes case)"
say ""

# --- build one corpus exercising every hazard at once ----------------------
src=$B/src
mkdir -p $src/sub/deep
print -n 'alpha'  > $src/a.txt
print -n 'beta'   > $src/sub/b.txt
print -n 'gamma'  > $src/sub/deep/c.txt
chmod 0755 $src/a.txt
chmod 0600 $src/sub/b.txt
chmod 0644 $src/sub/deep/c.txt
ln -s a.txt $src/link-to-a           # symlink
ln $src/sub/b.txt $src/hard-to-b     # hardlink
# One file above FileWriterPool.smallFileMax (4 MiB) to force the inline path,
# next to hundreds of small ones so both paths interleave.
# 一個超過 smallFileMax（4 MiB）的檔案以強制走 inline 路徑，旁邊放數百個小檔，
# 讓兩條路徑交錯。
head -c $((6 * 1024 * 1024)) /dev/urandom > $src/big.bin
for i in {1..400}; do print -n "small-$i" > $src/sub/s$i.dat; done
touch -t 202001020304.05 $src/a.txt $src/sub/b.txt

$ST -c --gzip -f $B/corpus.tgz -C $src . >/dev/null 2>&1 ||
  { say "FATAL: could not create the corpus"; print -rl -- $OUT > $REPORT; exit 1 }

# --- reference tree ---------------------------------------------------------
# Preferred reference is an INDEPENDENT tar. On macOS that is bsdtar. On the
# Linux guest /usr/bin/tar is a busybox wrapper that produced an EMPTY tree
# here, and an empty reference does not fail loudly -- it makes every entry
# look like an unexpected addition, which is exactly how this first showed up.
#
# So the reference is validated before use, and when it is unusable the
# comparison falls back to swift_tar at -n 1 versus swift_tar at higher -n.
# That is not a weaker test of the thing actually under review: the property
# the pool must preserve is that concurrency does not change the result.
#
# 首選參照是一個「獨立的」tar。macOS 上是 bsdtar；Linux guest 的 /usr/bin/tar 是
# busybox wrapper，在此產出空樹，而空的參照不會大聲失敗——它會讓每一個項目看起來
# 都像多出來的，這正是此問題最初的症狀。因此參照在使用前先驗證；不可用時改以
# 「swift_tar -n 1」對「swift_tar 較高 -n」比較。就本次要審查的東西而言這並不算
# 較弱的測試：池必須維持的性質正是「並行不改變結果」。
ref=$B/ref; mkdir -p $ref
$BSDTAR -xzf $B/corpus.tgz -C $ref 2>/dev/null
ref_kind="$BSDTAR (independent implementation)"
if [[ -z $(print -rl -- $ref/**/*(DN)) ]]; then
    say "NOTE: $BSDTAR produced an empty tree; falling back to swift_tar -n 1"
    say "註：$BSDTAR 產出空樹，改以 swift_tar -n 1 作為參照"
    say ""
    rm -rf $ref; mkdir -p $ref
    $ST -x -n 1 -f $B/corpus.tgz -C $ref >/dev/null 2>&1
    ref_kind="swift_tar -n 1 (independent tar unavailable here)"
fi

# Portability helpers. This script has to run on the Linux guest too, where
# there is no `shasum` (perl) and busybox's find/sort do not reliably support
# -print0 / -z. zsh is present on both, so use its globbing and skip the
# external tools entirely rather than depending on which coreutils variant is
# installed.
# 可攜性輔助。本腳本也要在 Linux guest 上執行，那裡沒有 shasum（perl），且
# busybox 的 find/sort 對 -print0 / -z 支援不可靠。兩邊都有 zsh，因此改用它的
# glob、完全不依賴外部工具，而非去猜裝的是哪一種 coreutils。
if (( $+commands[shasum] )); then
  sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
elif (( $+commands[sha256sum] )); then
  sha() { sha256sum "$1" | cut -d' ' -f1 }
else
  print -ru2 -- "no shasum or sha256sum"; exit 1
fi
# Mode and inode come from zsh's own stat module, not the `stat` command.
# The Linux guest has NO `stat` at all (this busybox is built without the
# applet), so the external tool returned nothing there and the permission and
# hardlink cases failed while the rest passed -- a measurement tool disagreeing
# with itself, which is the tool's bug and not the product's.
#
# NOTE the mask is written 8#7777, not 07777: zsh does NOT treat a leading zero
# as octal by default, so 07777 is decimal 7777 and silently yields the wrong
# permission bits (0754 came out as 0140).
#
# 權限與 inode 取自 zsh 自己的 stat 模組，而非外部 `stat` 指令。Linux guest 上
# 根本沒有 `stat`（此 busybox 未編入該 applet），外部指令在那裡回傳空值，導致
# 權限與 hardlink 案例失敗而其餘通過——量測工具自相矛盾，錯的是工具而非產品。
# 注意遮罩寫成 8#7777 而非 07777：zsh 預設不把前導 0 視為八進位，07777 會是
# 十進位 7777，並靜默算出錯誤的權限位元（0754 會變成 0140）。
zmodload -F zsh/stat b:zstat 2>/dev/null ||
  { print -ru2 -- "zsh/stat module unavailable"; exit 1 }
modeof()  { printf '%o' $(( $(zstat +mode "$1") & 8#7777 )) }
inodeof() { zstat +inode "$1" }

fingerprint() {  # stable description of a tree: path, type, mode, content hash
  local d=$1 p
  ( cd $d || return
    # (D) includes dotfiles, (N) tolerates an empty match, (oN) sorts by name.
    # (D) 含隱藏檔，(N) 容忍無匹配，(oN) 依名稱排序。
    for p in **/*(DN@oN) **/*(DN.oN) **/*(DN/oN); do
      if [[ -L $p ]]; then
        print -r -- "$p L $(readlink $p)"
      elif [[ -d $p ]]; then
        print -r -- "$p D $(modeof $p)"
      else
        print -r -- "$p F $(modeof $p) $(sha $p)"
      fi
    done | LC_ALL=C sort )
}

ref_fp=$(fingerprint $ref)

say "## 1. tree fingerprint matches the reference, at every -n, every repeat"
say "reference : $ref_kind"
say ""
say "Path, type, permission bits and content hash for every entry."
say "每個項目的路徑、型別、權限位元與內容雜湊。"
say ""
typeset -i mismatches=0
for n in $NVALUES; do
  for r in {1..$REPEATS}; do
    out=$B/out-$n-$r; mkdir -p $out
    $ST -x -n $n -f $B/corpus.tgz -C $out >/dev/null 2>&1
    if [[ $(fingerprint $out) != $ref_fp ]]; then
      (( ++mismatches ))
      say "  DIFF at -n $n run $r:"
      # Compared in zsh rather than with diff(1). Two reasons, both learned the
      # hard way: the Linux guest has no `diff` applet, so the report printed
      # bare "DIFF at ..." headers with nothing under them; and `diff | while
      # read` puts the loop in a subshell, discarding the say() appends. Either
      # one alone removes the only evidence a failure produces.
      # 以 zsh 比對而非 diff(1)。兩個理由都是踩過才知道的：Linux guest 沒有 diff
      # applet，報告因而只印出空的 "DIFF at ..." 標題；而 `diff | while read`
      # 會讓迴圈落在子 shell，丟棄 say() 的累加。任一項單獨發生，都會讓失敗時
      # 唯一的證據消失。
      local -a want=("${(@f)ref_fp}") got=("${(@f)$(fingerprint $out)}")
      local -A w g
      local ln
      for ln in $want; do w[$ln]=1; done
      for ln in $got;  do g[$ln]=1; done
      local -i shown=0
      for ln in $want; do
        (( shown >= 6 )) && break
        [[ -n ${g[$ln]:-} ]] || { say "      -expected: $ln"; (( ++shown )) }
      done
      for ln in $got; do
        (( shown >= 12 )) && break
        [[ -n ${w[$ln]:-} ]] || { say "      +actual  : $ln"; (( ++shown )) }
      done
    fi
    rm -rf $out
  done
done
check "identical to the reference across ${#NVALUES} -n values x $REPEATS repeats" \
      $(( mismatches == 0 ? 1 : 0 )) "$mismatches mismatching runs"

# --- 2. permissions in detail ----------------------------------------------
say ""
say "## 2. permission bits survive the pool"
say ""
say "The pool applies mode with fchmod on the write descriptor. open()'s mode"
say "argument alone would be masked by umask, so this is the case that catches"
say "a regression to umask defaults."
say "池以 fchmod 在寫入 fd 上套用權限。單靠 open() 的 mode 參數會被 umask 遮罩，"
say "因此本案例正是用來抓「退化為 umask 預設」的回歸。"
say ""
out=$B/perm; mkdir -p $out
$ST -x -n 8 -f $B/corpus.tgz -C $out >/dev/null 2>&1
for spec in "./a.txt:755" "./sub/b.txt:600" "./sub/deep/c.txt:644"; do
  f=${spec%%:*} want=${spec##*:}
  got=$(modeof $out/$f)
  say "  $f -> $got (want $want)"
  check "mode preserved: $f" $([[ $got == $want ]] && print 1 || print 0)
done

# --- 3. links ---------------------------------------------------------------
say ""
say "## 3. symlink and hardlink"
say ""
tgt=$(readlink $out/link-to-a 2>/dev/null || print '')
check "symlink points at its target" $([[ $tgt == a.txt ]] && print 1 || print 0) "got '$tgt'"
check "symlink was not overwritten by a queued write" \
      $([[ -L $out/link-to-a ]] && print 1 || print 0) "must still be a symlink, not a regular file"
i1=$(inodeof $out/sub/b.txt)
i2=$(inodeof $out/hard-to-b)
check "hardlink shares an inode with its target" \
      $([[ -n $i1 && $i1 == $i2 ]] && print 1 || print 0) "inodes $i1 / $i2"

# --- 4. mtime ---------------------------------------------------------------
say ""
say "## 4. mtime is restored by the worker (futimens), not the main thread"
say ""
mt=$(zstat +mtime $out/a.txt)
want=$(zstat +mtime $src/a.txt)
say "  a.txt mtime $mt (source $want)"
check "mtime preserved through the pool" $([[ $mt == $want ]] && print 1 || print 0)

# --- 5. big file took the inline path and is still byte-exact ---------------
say ""
say "## 5. large file (inline path) alongside 400 pooled small files"
say ""
h1=$(shasum -a 256 $src/big.bin | cut -d' ' -f1)
h2=$(shasum -a 256 $out/big.bin | cut -d' ' -f1)
check "6 MiB file is byte-identical" $([[ $h1 == $h2 ]] && print 1 || print 0)
nsmall=$(ls $out/sub/s*.dat 2>/dev/null | wc -l | tr -d ' ')
check "all 400 small files present" $([[ $nsmall == 400 ]] && print 1 || print 0) "found $nsmall"
rm -rf $out

# --- 6. duplicate path: the LAST entry must win -----------------------------
say ""
say "## 6. duplicate path -- tar overwrite semantics"
say ""
say "Two members with the same name. Sequential extraction gets this for free;"
say "concurrent writes do not, which is why submit() drains on a repeat path."
say "兩個同名成員。序列解壓天生正確；並行寫入不然——這正是 submit() 在遇到重複"
say "路徑時要 drain 的原因。"
say ""
d1=$B/d1; d2=$B/d2; mkdir -p $d1 $d2
print -n 'FIRST'  > $d1/dup.txt
print -n 'SECOND' > $d2/dup.txt
# Append so the same name appears twice, second occurrence last. Built with
# swift_tar's own -r rather than `tar -rf`: on the Linux guest /usr/bin/tar is
# a busybox wrapper with no append support, and this case must run there too.
# 以 append 讓同名出現兩次、第二筆在後。使用 swift_tar 自己的 -r 而非 `tar -rf`：
# Linux guest 的 /usr/bin/tar 是 busybox wrapper，不支援 append，而本案例也必須
# 能在該處執行。
$ST -c -f $B/dup.tar -C $d1 dup.txt >/dev/null 2>&1
$ST -r -f $B/dup.tar -C $d2 dup.txt >/dev/null 2>&1
typeset -i dup_members=$($ST -t -f $B/dup.tar 2>/dev/null | LC_ALL=C grep -c 'dup\.txt')
if (( dup_members != 2 )); then
  # Report the missing precondition instead of a result. A one-member archive
  # would pass this case trivially and prove nothing.
  # 前提不成立時回報前提，而非回報結果。單成員封存會輕易通過本案例，卻什麼也
  # 沒證明。
  say "  SKIP: could not build a two-member archive (found $dup_members)"
  check "last duplicate entry wins, all runs" 1 "SKIPPED -- input could not be constructed"
else
  typeset -i dup_bad=0
  for n in $NVALUES; do
    for r in {1..$REPEATS}; do
      o=$B/dupo; rm -rf $o; mkdir -p $o
      $ST -x -n $n -f $B/dup.tar -C $o >/dev/null 2>&1
      [[ $(cat $o/dup.txt 2>/dev/null) == SECOND ]] || (( ++dup_bad ))
    done
  done
  check "last duplicate entry wins, all runs" $(( dup_bad == 0 ? 1 : 0 )) "$dup_bad wrong"
fi

# --- 7. worker failure must surface -----------------------------------------
say ""
say "## 7. a failing write must produce a non-zero exit"
say ""
say "Errors happen on a worker thread. Without the drain-then-check at the end"
say "of extraction, they would be discarded and the run would report success."
say "錯誤發生在 worker 執行緒上。若解壓結尾沒有「先 drain 再檢查」，這些錯誤會被"
say "丟棄，而該次執行會回報成功。"
say ""
say "The archive here must NOT contain a './' member. The main corpus does (it"
say "was built with '-C src .'), and extracting that member restores the"
say "DESTINATION directory's own mode -- correct tar behaviour that silently"
say "undoes the read-only precondition. Archive a named file instead."
say "此處的封存不可含有 './' 成員。主語料含有（以 '-C src .' 建立），而解開該成員"
say "會還原「目的目錄本身」的權限——這是正確的 tar 行為，卻會靜默地解除唯讀前提。"
say "改為只封存具名檔案。"
say ""
fdir=$B/faildir; mkdir -p $fdir; print -n 'x' > $fdir/only.txt
$BSDTAR -czf $B/nodot.tgz -C $fdir only.txt 2>/dev/null

ro=$B/readonly; rm -rf $ro; mkdir -p $ro; chmod 0555 $ro
# Establish the precondition instead of assuming it. If this environment lets
# the owner write into a 0555 directory, the case proves nothing and must say
# so rather than reporting a pass or a failure it did not test.
# 主動確立前提而非假設。若此環境允許擁有者寫入 0555 目錄，本案例什麼都證明不了，
# 必須明說，而不是回報一個它根本沒測到的通過或失敗。
if touch $ro/.probe 2>/dev/null; then
    rm -f $ro/.probe; chmod 0755 $ro
    say "  SKIP: this filesystem lets the owner write into a 0555 directory"
    check "unwritable destination fails loudly" 1 "SKIPPED -- precondition unavailable here"
else
    $ST -x -n 8 -f $B/nodot.tgz -C $ro >/dev/null 2>&1
    rc=$?
    chmod 0755 $ro
    say "  extracting into a read-only directory -> exit $rc"
    check "unwritable destination fails loudly" $(( rc != 0 ? 1 : 0 )) "exit was $rc"
fi

# --- summary ----------------------------------------------------------------
typeset -i pass=0
for r in $RES; do (( r == 1 )) && (( ++pass )); done
say ""
say "## summary: $pass/${#RES} passed"
for i in {1..${#NAMES}}; do
  say "  $([[ $RES[i] == 1 ]] && print PASS || print FAIL)  $NAMES[i]"
done

print -rl -- $OUT > $REPORT
print -r -- ""
print -r -- "report: $REPORT"
(( pass == ${#RES} )) && exit 0 || exit 1
