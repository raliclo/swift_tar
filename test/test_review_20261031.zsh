#!/usr/bin/env zsh
# test/test_review_20261031.zsh -- pin the fixes for the 2026-10-31 review's high items H1-H7.
# test/test_review_20261031.zsh -- 釘住 2026-10-31 審查高風險項 H1-H7 的修正。
#
#   ./test/test_review_20261031.zsh          run against release/swift_tar / 以 release/swift_tar 執行
#   ST=/path/to/swift_tar ./test/...         run against another binary / 以其他執行檔執行
#   ./test/test_review_20261031.zsh --help   print this synopsis and exit / 印出本說明後結束
#
# Every item was reproduced against 0.1.4 before the fix; each check below fails there.
# See todo/todo.md, "2026-10-31 whole-tree code review", for the items.
# 每一項都先以 0.1.4 重現過；下列每項檢查在 0.1.4 上都失敗。各項見 todo/todo.md 的
# 「2026-10-31 全樹程式碼審查」。
set -euo pipefail
setopt extended_glob

script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,12p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

ROOT="${script_path:h:h}"
windows=0
if [[ -z ${ST:-} ]]; then
  case "$(uname -s)" in
    MSYS*|MINGW*|CYGWIN*) ST="$ROOT/release/swift_tar.exe" ;;
    *) ST="$ROOT/release/swift_tar" ;;
  esac
fi
[[ $(uname -s) == (MSYS|MINGW|CYGWIN)* ]] && windows=1
[[ -x $ST ]] || { print -u2 "error: build first -- missing $ST / 請先建置"; exit 1 }
RAW="$ROOT/verifications/make_raw_tar.zsh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0 fail=0 skip=0
ok()   { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad()  { print -r -- "FAIL: $1"; fail=$((fail + 1)) }
skipc(){ print -r -- "SKIP: $1"; skip=$((skip + 1)) }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi }
# Permission bits as octal, on BSD and GNU stat. / 權限位元（八進位），BSD 與 GNU stat 皆可。
if [[ $(uname -s) == Darwin ]]; then perm() { stat -f %Lp -- "$1" }; else perm() { stat -c %a -- "$1" }; fi
# Run swift_tar; its status goes to $rc, both streams to $TMP/out. / 執行並把退出碼放在 $rc。
run() { rc=0; "$ST" "$@" >"$TMP/out" 2>&1 || rc=$? }
raw() { "$RAW" "$@" >/dev/null }

# --- H1: a link or FIFO member must not delete a non-empty directory -----------------
# --- H1：連結或 FIFO 成員不得刪除非空目錄 ---------------------------------------------
cd "$TMP"
raw h1.tar link Documents /nonexistent
mkdir -p o1/Documents; print important > o1/Documents/file
run -xf h1.tar -C o1
check "H1 symlink over a non-empty dir: exits non-zero / 非空目錄上的 symlink：以非 0 結束" '(( rc != 0 ))'
check "H1 symlink over a non-empty dir: the directory and its file survive / 目錄與檔案保留" \
  '[[ -d o1/Documents && ! -L o1/Documents && $(<o1/Documents/file) == important ]]'
check "H1 symlink: stderr names the directory / stderr 指出該目錄" 'grep -q "non-empty directory" "$TMP/out"'

raw h1h.tar file other x hard Documents other
mkdir -p o1h/Documents; print important > o1h/Documents/file
run -xf h1h.tar -C o1h
check "H1 hardlink over a non-empty dir: the file survives / 非空目錄上的硬連結：檔案保留" \
  '(( rc != 0 )) && [[ $(<o1h/Documents/file) == important ]]'

if (( windows )); then
  skipc "H1 FIFO: Windows has no FIFOs / Windows 沒有 FIFO"
else
  raw h1f.tar fifo Documents -
  mkdir -p o1f/Documents; print important > o1f/Documents/file
  run -xf h1f.tar -C o1f
  check "H1 FIFO over a non-empty dir: the file survives / 非空目錄上的 FIFO：檔案保留" \
    '(( rc != 0 )) && [[ $(<o1f/Documents/file) == important ]]'
fi

# Control: an EMPTY directory is still replaced, as both reference tars do.
# 對照組：空目錄照樣被取代，與兩個參照實作相同。
mkdir -p o1e/Documents
run -xf h1.tar -C o1e
check "H1 control: a symlink replaces an empty dir, exit 0 / 對照：symlink 取代空目錄，以 0 結束" \
  '(( rc == 0 )) && [[ -L o1e/Documents ]]'

# --- H2: a directory member must not chmod through a symlink member --------------------
# --- H2：目錄成員不得穿過 symlink 成員去 chmod ------------------------------------------
if (( windows )); then
  skipc "H2: no POSIX modes on Windows / Windows 沒有 POSIX mode"
else
  mkdir -p outside2 o2; chmod 755 outside2
  RAW_TAR_MODE=0000777 raw h2.tar link l "$TMP/outside2" dir l/ -
  run -xf h2.tar -C o2
  check "H2 the directory outside -C keeps its mode / -C 外的目錄保留其權限" '[[ $(perm outside2) == 755 ]]'
  check "H2 l is now a real directory, not the link / l 成為真正的目錄而非連結" '[[ -d o2/l && ! -L o2/l ]]'
fi

# --- H3: -C below a regular file must not delete that file -----------------------------
# --- H3：位於一般檔案之下的 -C 不得刪掉該檔案 --------------------------------------------
raw h3.tar file a.txt hello
mkdir -p w3; print PRECIOUS > w3/thesis.docx
( cd w3 && "$ST" -xf ../h3.tar -C thesis.docx/restore ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "H3 relative -C under a file: exits non-zero / 相對 -C 位於檔案之下：以非 0 結束" '(( rc != 0 ))'
check "H3 relative -C under a file: the file survives / 該檔案保留" \
  '[[ -f w3/thesis.docx && $(<w3/thesis.docx) == PRECIOUS ]]'
run -xf h3.tar -C "$TMP/w3/thesis.docx/restore"
check "H3 absolute -C under a file: the file survives / 絕對 -C：該檔案保留" \
  '(( rc != 0 )) && [[ -f w3/thesis.docx && $(<w3/thesis.docx) == PRECIOUS ]]'

# Control: a file the ARCHIVE claims as a directory is still cleared, with an absolute -C
# (the walk used to drop the leading "/" and look relative to the working directory).
# 對照組：封存聲稱為目錄的檔案照樣被清掉，且用絕對 -C（走訪過去會丟掉開頭的 "/"，改看工作目錄）。
raw h3c.tar file cfg/x inner
mkdir -p o3c; print old > o3c/cfg
run -xf h3c.tar -C "$TMP/o3c"
check "H3 control: an archive-claimed blocker below an absolute -C is replaced / 對照：絕對 -C 之下的阻擋物被取代" \
  '(( rc == 0 )) && [[ -d o3c/cfg && $(<o3c/cfg/x) == inner ]]'

# --- H4: a mode field of 0o200000 or more must not trap ----------------------------------
# --- H4：mode 欄位 0o200000 以上不得 trap ------------------------------------------------
RAW_TAR_MODE=0200644 raw h4.tar file f hi
mkdir -p o4
run -xf h4.tar -C o4
check "H4 file mode 0200644: exits 0 / 以 0 結束" '(( rc == 0 ))'
check "H4 file mode 0200644: content written / 內容寫出" '[[ $(<o4/f) == hi ]]'
if (( ! windows )); then
  check "H4 file mode 0200644: high bits dropped, 644 kept / 去掉高位、保留 644" '[[ $(perm o4/f) == 644 ]]'
fi
RAW_TAR_MODE=0200755 raw h4d.tar dir d/ -
mkdir -p o4d
run -xf h4d.tar -C o4d
check "H4 directory mode 0200755: exits 0, directory made / 目錄：以 0 結束並建立" '(( rc == 0 )) && [[ -d o4d/d ]]'
run -tf h4.tar
check "H4 -t lists it / -t 列出" '(( rc == 0 )) && grep -qx f "$TMP/out"'

# --- H5: a value option with no value is an error -----------------------------------------
# --- H5：沒有值的值選項是錯誤 ---------------------------------------------------------------
mkdir -p d5; print secret > d5/s
run -c --zstd -f h5.tar.zst d5 --keyfile
check "H5 trailing --keyfile: exits non-zero / 結尾的 --keyfile：以非 0 結束" '(( rc != 0 ))'
check "H5 trailing --keyfile: no archive written / 不寫出封存" '[[ ! -e h5.tar.zst ]]'
check "H5 trailing --keyfile: says it needs an argument / 說明需要值" 'grep -q "requires an argument" "$TMP/out"'
raw h5x.tar file a.txt hello
mkdir -p w5
( cd w5 && "$ST" -xf ../h5x.tar -C ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "H5 trailing -C: exits non-zero, nothing extracted here / 結尾的 -C：非 0 且未解出" \
  '(( rc != 0 )) && [[ ! -e w5/a.txt ]]'

# --- H6: -r/-u on something that is not a tar leaves it alone -----------------------------
# --- H6：對非 tar 的檔案做 -r/-u 不得動它 ----------------------------------------------------
print -l {1..200} > notes.txt; cp notes.txt notes.orig
print x > x6
run -rf notes.txt x6
check "H6 -r on a 692-byte text file: exits non-zero / 對 692 位元組文字檔 -r：以非 0 結束" '(( rc != 0 ))'
check "H6 -r on a text file: file unchanged / 檔案不變" 'cmp -s notes.txt notes.orig'
print short > short.txt; cp short.txt short.orig
run -uf short.txt x6
check "H6 -u on a file under one block: file unchanged / 不滿一區塊的檔案 -u：不變" \
  '(( rc != 0 )) && cmp -s short.txt short.orig'
# Control: a real tar still takes the append. / 對照組：真正的 tar 照樣能附加。
"$ST" -cf real6.tar notes.orig
run -rf real6.tar x6
check "H6 control: -r on a real tar appends / 對照：真正的 tar 可以 -r" \
  '(( rc == 0 )) && "$ST" -tf real6.tar | grep -qx x6'

# --- H7: a queued write must not land through a symlink planted after it ------------------
# --- H7：排隊中的寫入不得穿過其後植入的 symlink 落地 ----------------------------------------
# A race, so the triple is repeated; before the fix a single run could leave files outside.
# 這是競態，所以三元組重複多次；修正前單次執行就可能在外部留下檔案。
mkdir -p outside7 o7
args=()
for i in {1..150}; do args+=(dir "d$i/" - file "d$i/x" payload link "d$i" "$TMP/outside7"); done
# 0755: the default 0644 would leave the directories untraversable. / 預設 0644 會讓目錄無法進入。
RAW_TAR_MODE=0000755 raw h7.tar $args
run -xf h7.tar -C o7 -n 8
leaked=( outside7/*(N) )
check "H7 nothing written outside -C (150 triples) / 150 組三元組：-C 之外沒有檔案" '(( ${#leaked} == 0 ))'
check "H7 every queued file landed inside -C / 每個排隊的檔案都在 -C 之內" '[[ $(<o7/d150/x) == payload ]]'

print -r -- "PASS: $pass  FAIL: $fail  SKIP: $skip"
(( fail == 0 ))
