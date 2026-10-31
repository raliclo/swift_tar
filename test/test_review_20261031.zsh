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
# $TMP as a native exe sees it: on Windows the shell's /tmp/... means nothing to swift_tar.exe.
# 原生 exe 看得懂的 $TMP：Windows 上 shell 的 /tmp/... 對 swift_tar.exe 沒有意義。
if (( windows )); then NTMP=$(cygpath -m -- "$TMP"); else NTMP=$TMP; fi

pass=0 fail=0 skip=0
ok()   { print -r -- "PASS: $1"; pass=$((pass + 1)) }
bad()  { print -r -- "FAIL: $1"; fail=$((fail + 1)) }
skipc(){ print -r -- "SKIP: $1"; skip=$((skip + 1)) }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi }
# Permission bits as octal, on BSD and GNU stat. / 權限位元（八進位），BSD 與 GNU stat 皆可。
if [[ $(uname -s) == Darwin ]]; then perm() { stat -f %Lp -- "$1" }; else perm() { stat -c %a -- "$1" }; fi
# Same, keeping setuid/setgid/sticky: BSD %Lp drops them, so a setuid check with perm() cannot
# fail. / 同上但保留 setuid／setgid／sticky：BSD 的 %Lp 會丟掉它們，用 perm() 檢查 setuid 永遠不會失敗。
fperm() {
  local p
  if [[ $(uname -s) == Darwin ]]; then p=$(stat -f %p -- "$1"); p=${p[-4,-1]}; else p=$(stat -c %a -- "$1"); fi
  print -r -- "${p##0}"
}
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
run -xf h3.tar -C "$NTMP/w3/thesis.docx/restore"
check "H3 absolute -C under a file: the file survives / 絕對 -C：該檔案保留" \
  '(( rc != 0 )) && [[ -f w3/thesis.docx && $(<w3/thesis.docx) == PRECIOUS ]]'

# Control: a file the ARCHIVE claims as a directory is still cleared, with an absolute -C
# (the walk used to drop the leading "/" and look relative to the working directory).
# 對照組：封存聲稱為目錄的檔案照樣被清掉，且用絕對 -C（走訪過去會丟掉開頭的 "/"，改看工作目錄）。
raw h3c.tar file cfg/x inner
mkdir -p o3c; print old > o3c/cfg
run -xf h3c.tar -C "$NTMP/o3c"
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

# --- H9 (Windows): a drive prefix behind a slash must not survive sanitising --------------
# --- H9（Windows）：斜線後面的磁碟代號不得通過清理 ---------------------------------------
if (( windows )); then
  raw h9.tar file '/C:/h9_escape.txt' x
  mkdir -p w9
  ( cd w9 && "$ST" -xf ../h9.tar ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "H9 /C:/x without -C is not written to the drive root / 不寫到磁碟根目錄" '[[ ! -e /c/h9_escape.txt ]]'
else
  skipc "H9: Windows only / 僅 Windows"
fi

# --- H10: hostile scrypt parameters are refused before key derivation --------------------
# --- H10：惡意 scrypt 參數在推導金鑰之前就被拒絕 ------------------------------------------
# The header is bytes 0-7 magic, 8 version, 9 kdf, 10 logN, 11 r, 12 p. A keyfile header
# never ran its scrypt values through the bound; the passphrase path then derived with them.
# 標頭：0-7 magic、8 版本、9 kdf、10 logN、11 r、12 p。keyfile 標頭的 scrypt 值過去不受上限檢查，
# 而 passphrase 路徑會拿它們去推導。
mkdir -p d10; print data > d10/f; head -c 32 /dev/urandom > key10
"$ST" -c --keyfile key10 -f h10.enc d10
cp h10.enc h10r.enc; printf '\0' | dd of=h10r.enc bs=1 seek=11 conv=notrunc 2>"$TMP/dd.err" || cat "$TMP/dd.err"
run -tf h10r.enc --keyfile key10
check "H10 r=0 in a keyfile header: refused as out of range / keyfile 標頭 r=0：以超出範圍拒絕" \
  '(( rc != 0 )) && grep -q "out of range" "$TMP/out"'
cp h10.enc h10k.enc; printf '\001' | dd of=h10k.enc bs=1 seek=9 conv=notrunc 2>"$TMP/dd.err" || cat "$TMP/dd.err"
run -tf h10k.enc --keyfile key10
check "H10 kdf says passphrase, keyfile given: names the mismatch / kdf 與密碼種類不符：說明需要哪一種" \
  '(( rc != 0 )) && grep -q "encrypted with a passphrase" "$TMP/out"'
run -tf h10.enc --keyfile key10
check "H10 control: the untouched archive lists / 對照：未改動的封存可列出" '(( rc == 0 )) && grep -q "d10/f" "$TMP/out"'

# --- M1: a missing operand or a vanished file does not end the run -----------------------
# --- M1：缺少的運算元或消失的檔案不會結束整次執行 -----------------------------------------
mkdir -p m1a m1b; print a > m1a/a; print b > m1b/b
run -cf m1.tar m1a missing_m1 m1b
check "M1 a missing operand: exits non-zero / 缺少的運算元：以非 0 結束" '(( rc != 0 ))'
check "M1 a missing operand: the operand after it is stored / 其後的運算元照樣收入" \
  '"$ST" -tf m1.tar | grep -qx "m1b/b"'
check "M1 a missing operand: the archive is complete (two zero blocks) / 封存完整（兩個零區塊）" \
  '[[ $(tail -c 1024 m1.tar | tr -d "\\0" | wc -c | tr -d " ") == 0 ]]'

# --- M2: a truncated .tar.bz2 is an error ----------------------------------------------------
# --- M2：截斷的 .tar.bz2 是錯誤 --------------------------------------------------------------
mkdir -p m2; for i in {1..50}; do print "line $i of some text" > m2/f$i.txt; done
"$ST" -cjf m2.tar.bz2 m2
head -c 500 m2.tar.bz2 > m2cut.tar.bz2
run -tf m2cut.tar.bz2
check "M2 a .tar.bz2 cut inside its first block: exits non-zero / 首區塊內截斷：以非 0 結束" '(( rc != 0 ))'
run -tf m2.tar.bz2
check "M2 control: the whole .tar.bz2 lists 51 entries / 對照：完整檔列出 51 項" \
  '(( rc == 0 )) && [[ $(wc -l < "$TMP/out" | tr -d " ") == 51 ]]'

# --- M3: a control byte in a uuencoded body is a format error, not a trap -----------------
# --- M3：uuencode 內文中的控制字元是格式錯誤，不是 trap ------------------------------------
printf 'begin 644 x\n\tAB\nend\n' > m3.uu
run -tf m3.uu
check "M3 a tab in the uu body: fails cleanly, no signal / uu 內文含 tab：乾淨失敗、無訊號" '(( rc != 0 && rc < 128 ))'

# --- M5: the traditional `cfv` form takes the archive name from the next word ------------
# --- M5：傳統寫法 `cfv` 從下一個字取封存名稱 ----------------------------------------------
mkdir -p w5b/d; print x > w5b/d/x
( cd w5b && "$ST" cfv out.tar d ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "M5 cfv out.tar d: writes out.tar, not a file named -v / 寫出 out.tar 而非名為 -v 的檔案" \
  '(( rc == 0 )) && [[ -f w5b/out.tar && ! -e w5b/-v ]]'
check "M5 cfv: out.tar holds d/x / out.tar 含 d/x" '"$ST" -tf w5b/out.tar | grep -qx "d/x"'

# --- M4: on POSIX "\" and "X:" are part of a name, not path syntax -------------------------
# --- M4：POSIX 上 "\" 與 "X:" 是名稱的一部分，不是路徑語法 ---------------------------------
if (( windows )); then
  skipc "M4 is POSIX-only: Windows cannot name a file with a backslash / M4 僅適用 POSIX"
else
  mkdir -p m4; print x > 'm4/foo\bar.txt'; print y > 'C:x4'
  run -cf m4.tar 'm4/foo\bar.txt' 'C:x4'
  check "M4 foo\\bar.txt is stored as named / 照原名存入" '"$ST" -tf m4.tar | grep -qxF "m4/foo\\bar.txt"'
  check "M4 C:x4 keeps its C: / C:x4 保留 C:" '"$ST" -tf m4.tar | grep -qxF "C:x4"'
  # bsdtar -t prints "\" as "\\", so compare what it extracts. / bsdtar -t 把 "\" 印成 "\\"，故比對解出結果。
  mkdir -p o4
  if command -v bsdtar >/dev/null; then
    check "M4 bsdtar extracts the same name / bsdtar 解出相同名稱" \
      'bsdtar -xf m4.tar -C o4 && [[ -f "o4/m4/foo\\bar.txt" ]]'
  else
    skipc "M4 bsdtar cross-check: no bsdtar on PATH / PATH 上沒有 bsdtar"
  fi
fi

# --- M6: a uid/gid above 2097151 is carried in pax, not truncated --------------------------
# --- M6：超過 2097151 的 uid/gid 以 pax 帶出，不被截斷 -------------------------------------
# swift_tar takes uid/gid from stat, so the test needs a file that stat reports as owned by
# 3000000. Linux: an unprivileged user namespace maps our uid to it, no root needed. Else, as
# root, chown. Otherwise (macOS as a user) SKIP. No sudo.
# swift_tar 的 uid/gid 取自 stat，所以需要一個 stat 回報為 3000000 所有的檔案。Linux：以非特權
# user namespace 把自己的 uid 對應過去，不需要 root。否則若是 root 就 chown。其他（macOS 一般
# 使用者）SKIP。不用 sudo。
mkdir -p m6; print x > m6/f
m6how=""
if (( windows )); then
  :
elif command -v unshare >/dev/null && unshare --user --map-user=3000000 --map-group=3000001 true >"$TMP/m6.probe" 2>&1; then
  m6how=unshare
  rc=0; unshare --user --map-user=3000000 --map-group=3000001 "$ST" -cf m6.tar m6/f >"$TMP/out" 2>&1 || rc=$?
elif (( $(id -u) == 0 )); then
  m6how=chown
  chown 3000000:3000001 m6/f
  run -cf m6.tar m6/f
fi
if [[ -z $m6how ]]; then
  skipc "M6 needs Linux user namespaces or root to make a file owned by uid 3000000 / M6 需要 Linux user namespace 或 root"
else
  # bsdtar prints "3000000 3000001", GNU tar "3000000/3000001". / 兩種 tar 的格式都接受。
  if command -v bsdtar >/dev/null; then m6list=$(bsdtar -tvf m6.tar --numeric-owner); else m6list=$(tar --numeric-owner -tvf m6.tar); fi
  check "M6 ($m6how) another tar reads uid 3000000 and gid 3000001 / 另一個 tar 讀到 uid 3000000、gid 3000001" \
    '(( rc == 0 )) && [[ $m6list == *3000000*3000001* ]]'
fi

# --- M7: -t and -x agree on which members carry data ---------------------------------------
# --- M7：-t 與 -x 對哪些成員帶資料的判斷一致 -----------------------------------------------
# A member whose size is not data is followed by a real header, here evil.txt's. bsdtar 3.8.8
# reads the size as data only for types other than 1-6 and not for a name ending in "/".
# size 不代表資料的成員之後緊接真正的標頭（此處為 evil.txt 的）。bsdtar 3.8.8 只對類型 1–6
# 以外、且名稱不以 "/" 結尾者把 size 當資料。
settype() {  # <tar> <typeflag>: rewrite the first header's type and its checksum / 改寫首標頭型別與校驗和
  local f=$1 sum=0 b
  printf '%s' "$2" | dd of="$f" bs=1 seek=156 conv=notrunc 2>"$TMP/dd.err"
  printf '        ' | dd of="$f" bs=1 seek=148 conv=notrunc 2>"$TMP/dd.err"
  for b in $(od -v -An -tu1 -N512 "$f"); do (( sum += b )); done
  printf '%06o\0 ' $sum | dd of="$f" bs=1 seek=148 conv=notrunc 2>"$TMP/dd.err"
}
raw m7in.tar file evil.txt EVIL
m7pad=$(printf 'A%.0s' {1..1024})
m7() {  # <out> <name> <type>: a member carrying 1024 bytes that are evil.txt's header and data
  raw "$1" file "$2" "$m7pad"
  dd if=m7in.tar of="$1" bs=512 seek=1 count=2 conv=notrunc 2>"$TMP/dd.err"
  [[ $3 == 0 ]] || settype "$1" "$3"
}
m7 m7d.tar d/ 0
run -tf m7d.tar
check "M7 type-0 'd/' with data: -t lists the evil.txt that -x writes / -t 列出 -x 會寫出的 evil.txt" \
  '(( rc == 0 )) && grep -qx evil.txt "$TMP/out"'
mkdir -p o7d; run -xf m7d.tar -C o7d
check "M7 type-0 'd/': -x writes evil.txt too / -x 也寫出 evil.txt" '[[ -f o7d/evil.txt ]]'
m7 m7s.tar s 2
run -tf m7s.tar --exclude s
check "M7 an excluded symlink with a size: -t still sees evil.txt / 被排除的 symlink：-t 仍看到 evil.txt" \
  'grep -qx evil.txt "$TMP/out"'
mkdir -p o7s; run -xf m7s.tar -C o7s --exclude s
check "M7 an excluded symlink with a size: -x still writes evil.txt / -x 仍寫出 evil.txt" '[[ -f o7s/evil.txt ]]'
m7 m7c.tar c 3
mkdir -p o7c; run -xf m7c.tar -C o7c --no-strict
check "M7 a type-3 member with a size: -x writes the evil.txt that -t lists / -x 寫出 -t 列出的 evil.txt" \
  '[[ -f o7c/evil.txt ]] && "$ST" -tf m7c.tar | grep -qx evil.txt'
m7 m7f.tar f 0
run -tf m7f.tar
check "M7 control: a regular file's data is skipped, evil.txt not listed / 對照：一般檔資料被略過" \
  '(( rc == 0 )) && ! grep -qx evil.txt "$TMP/out"'

# --- M8: --no-same-permissions applies to directories, large files and FIFOs too ----------
# --- M8：--no-same-permissions 也作用於目錄、大檔與 FIFO -----------------------------------
if (( windows )); then
  skipc "M8 is POSIX-only: Windows has no mode bits to mask / M8 僅適用 POSIX"
else
  mkdir -p m8/d; chmod 777 m8/d
  dd if=/dev/zero of=m8/big bs=1048576 count=5 2>"$TMP/dd.err"; chmod 666 m8/big
  print s > m8/small; chmod 666 m8/small
  mkfifo m8/p; chmod 666 m8/p
  run -cf m8.tar m8
  mkdir -p o8; ( umask 022; "$ST" -xf m8.tar -C o8 --no-same-permissions ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "M8 extracts / 解出成功" '(( rc == 0 ))'
  check "M8 a directory gets 0777 & ~022 / 目錄得 755" '[[ $(perm o8/m8/d) == 755 ]]'
  check "M8 a file above 4 MiB gets 0666 & ~022 / 大於 4 MiB 的檔得 644" '[[ $(perm o8/m8/big) == 644 ]]'
  check "M8 a FIFO gets 0666 & ~022 / FIFO 得 644" '[[ $(perm o8/m8/p) == 644 ]]'
  check "M8 control: a small file gets 644 / 對照：小檔得 644" '[[ $(perm o8/m8/small) == 644 ]]'
  mkdir -p o8p; ( umask 022; "$ST" -xf m8.tar -C o8p ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "M8 control: without the flag the modes are restored / 對照：不加旗標則原樣還原" \
    '[[ $(perm o8p/m8/d) == 777 && $(perm o8p/m8/big) == 666 && $(perm o8p/m8/p) == 666 ]]'
fi

# --- M13: a hardlink whose target is missing skips that member, not the rest ---------------
# --- M13：目標不存在的硬連結只略過該成員，不中止其餘 -----------------------------------------
raw m13.tar hard h13 missing13 file after13.txt A
mkdir -p o13; run -xf m13.tar -C o13
check "M13 a hardlink to a missing target: exits non-zero / 目標不存在：以非 0 結束" '(( rc != 0 ))'
check "M13 the member after it is still written / 其後的成員照樣寫出" '[[ $(<o13/after13.txt) == A ]]'
check "M13 stderr names the hardlink / stderr 指出該硬連結" 'grep -q "skipping hardlink .*h13" "$TMP/out"'

# --- M15: a second -C is refused rather than taken as an operand ---------------------------
# --- M15：第二個 -C 被拒絕，而不是被當成運算元 ---------------------------------------------
mkdir -p m15a m15b; print 1 > m15a/f1; print 2 > m15b/f2
run -cf m15.tar -C m15a f1 -C m15b f2
check "M15 two -C: exits non-zero and says only one is supported / 兩個 -C：非 0 並說明只支援一個" \
  '(( rc != 0 )) && grep -q "only one -C" "$TMP/out"'
run -cf m15c.tar -C m15a f1
check "M15 control: one -C works / 對照：一個 -C 可用" '(( rc == 0 )) && "$ST" -tf m15c.tar | grep -qx f1'

# --- M16: -test run by a bare name through PATH finds itself ------------------------------
# --- M16：經 PATH 以裸名稱執行 -test 能找到自己 --------------------------------------------
if (( windows )); then
  skipc "M16 is the POSIX half; Windows already searched PATH / M16 為 POSIX 部分"
else
  mkdir -p m16
  ( cd m16 && PATH="${ST:h}:$PATH" "${ST:t}" -test ) >"$TMP/m16.out" 2>&1 && rc=0 || rc=$?
  check "M16 bare-name -test passes / 裸名稱 -test 通過" '(( rc == 0 )) && ! grep -q "FAILED" "$TMP/m16.out"'
fi

# --- M17: a NUL inside a long name cannot hide a ".." --------------------------------------
# --- M17：長檔名內的 NUL 不能藏住 ".." ------------------------------------------------------
# A GNU L record "..<NUL>AAAA/" names the next member, a directory with mode 0777. The C calls
# see "..". On macOS 0.1.4 is not hurt by it -- FileManager refuses a path holding a NUL, so the
# directory is skipped before any chmod -- and the two mode checks pass there too; they stay as
# guards because Linux's Foundation was not measured. The -t check is the one 0.1.4 fails: it
# listed "..<NUL>AAAA/", a name no C call sees.
# GNU L 記錄 "..<NUL>AAAA/" 為下一個成員命名，該成員是 mode 0777 的目錄。C 呼叫看到的是 ".."。
# macOS 上 0.1.4 不受影響——FileManager 拒絕含 NUL 的路徑，目錄在任何 chmod 之前就被略過——所以
# 兩項 mode 檢查在 0.1.4 上也通過；保留為防護，因為 Linux 的 Foundation 沒有量過。0.1.4 失敗的是
# -t 那一項：它列出 "..<NUL>AAAA/"，一個沒有任何 C 呼叫看得到的名稱。
RAW_TAR_MODE=0000777 "$RAW" m17.tar file '././@LongLink' '..ZAAAA/' dir placeholder/ - >/dev/null
printf '\0' | dd of=m17.tar bs=1 seek=514 conv=notrunc 2>"$TMP/dd.err"
settype m17.tar L
mkdir -p p17/o17; chmod 700 p17
run -xf m17.tar -C p17/o17
if (( windows )); then
  skipc "M17 mode checks: Windows has no POSIX modes / M17 權限檢查：Windows 沒有 POSIX 權限"
else
  check "M17 the parent of -C keeps mode 700 / -C 的上一層維持 700" '[[ $(perm p17) == 700 ]]'
  check "M17 -C itself is not chmodded either / -C 本身也沒被改" '[[ $(perm p17/o17) != 777 ]]'
fi
run -tf m17.tar
check "M17 -t shows the name as the C calls see it / -t 顯示 C 端看到的名稱" 'grep -qx ".." "$TMP/out"'

# --- M9: an RPM whose header is larger than one 64 KiB read ---------------------------------
# --- M9：header 大於一次 64 KiB 讀取的 RPM -------------------------------------------------
# Lead (96 bytes) + one header with hsize 70000 + a .tar.gz payload. Skipping the header makes
# ByteReader drop consumed bytes, after which 0.1.4 read the payload from the wrong offset.
# lead（96 位元組）+ 一個 hsize 為 70000 的 header + .tar.gz payload。略過 header 會讓
# ByteReader 丟掉已讀的位元組，之後 0.1.4 從錯的位移讀 payload。
mkdir -p m9/p; print hello > m9/p/a.txt
"$ST" -czf m9/payload.tgz -C m9 p
mkrpm() {  # <out> <hsize as 4 big-endian bytes, printf form> <hsize> / 建一個最小 RPM
  { printf '\xed\xab\xee\xdb'; dd if=/dev/zero bs=92 count=1 2>"$TMP/dd.err"
    printf "\\x8e\\xad\\xe8\\x01\\0\\0\\0\\0\\0\\0\\0\\0$2"
    dd if=/dev/zero bs="$3" count=1 2>"$TMP/dd.err"; cat m9/payload.tgz } > "$1"
}
mkrpm m9big.rpm '\0\x01\x11\x70' 70000
run -tf m9big.rpm
check "M9 an RPM with a 70000-byte header lists its payload / 70000 位元組 header 的 RPM 列出內容" \
  '(( rc == 0 )) && grep -qx "p/a.txt" "$TMP/out"'
mkrpm m9small.rpm '\0\0\0\x64' 100
run -tf m9small.rpm
check "M9 control: a 100-byte header lists too / 對照：100 位元組 header 也列出" \
  '(( rc == 0 )) && grep -qx "p/a.txt" "$TMP/out"'

# --- N1 and M10: zstd frames that do not come from swift_tar -------------------------------
# --- N1 與 M10：不是 swift_tar 寫出的 zstd frame ---------------------------------------------
# The zstd CLI fed from a pipe writes one frame with no stated size.
# N1 (found during the review): a highly compressible frame whose decoded size is a multiple
# of 4 MiB was reported as a decode failure. M10: --zstd-parallel decoded such a frame into a
# buffer doubled without bound (3.2 GB RSS for 1 GiB on 0.1.4).
# 從管線餵入的 zstd CLI 寫出一個沒有載明大小的 frame。N1（審查時另外發現）：高度可壓縮、
# 解開後恰為 4 MiB 倍數的 frame 被報成解碼失敗。M10：--zstd-parallel 把這種 frame 解進無上限
# 倍增的緩衝（0.1.4 解 1 GiB 用了 3.2 GB RSS）。
if ! command -v zstd >/dev/null; then
  skipc "N1/M10 need the zstd CLI to make a frame with no stated size / N1、M10 需要 zstd CLI"
else
  head -c 16777216 /dev/zero | zstd -q -c > n1.zst
  rc=0; "$ST" --cat -f n1.zst > n1.out 2>"$TMP/out" || rc=$?
  check "N1 16 MiB of zeros: --cat exits 0 / 16 MiB 的零：--cat 以 0 結束" '(( rc == 0 ))'
  check "N1 16 MiB of zeros: all 16777216 bytes out / 輸出完整 16777216 位元組" \
    '[[ $(wc -c < n1.out | tr -d " ") == 16777216 ]]'
  rm -f n1.out
  head -c 1073741824 /dev/zero | zstd -q -c > m10.zst
  if [[ $(uname -s) == Darwin ]]; then
    rc=0; /usr/bin/time -l "$ST" --cat --zstd-parallel -f m10.zst >/dev/null 2>"$TMP/m10.time" || rc=$?
    rss=$(awk '/maximum resident set size/ {print $1}' "$TMP/m10.time")
  elif [[ -x /usr/bin/time ]] && /usr/bin/time -f %M true >/dev/null 2>&1; then
    rc=0; /usr/bin/time -f 'RSSKB %M' "$ST" --cat --zstd-parallel -f m10.zst >/dev/null 2>"$TMP/m10.time" || rc=$?
    rss=$(( $(awk '/^RSSKB/ {print $2}' "$TMP/m10.time") * 1024 ))
  else
    rss=""
  fi
  if [[ -z $rss ]]; then
    skipc "M10 needs /usr/bin/time that reports peak RSS / M10 需要能回報峰值 RSS 的 /usr/bin/time"
  else
    check "M10 --zstd-parallel on a 1 GiB unsized frame: exits 0 / 以 0 結束" '(( rc == 0 ))'
    check "M10 --zstd-parallel on a 1 GiB unsized frame: peak RSS under 256 MiB (was 3.2 GB) / 峰值 RSS 低於 256 MiB" \
      '(( rss > 0 && rss < 268435456 ))'
  fi
fi

# --- N2: member operands select members on -x, -t and -O -----------------------------------
# --- N2：成員名稱在 -x、-t、-O 上選取成員 --------------------------------------------------
mkdir -p n2/sub; print a > n2/a.txt; print b > n2/b.log; print c > n2/sub/c.txt
run -cf n2.tar -C n2 a.txt b.log sub
mkdir -p o2n; run -xf n2.tar -C o2n b.log
check "N2 -x b.log extracts only b.log / -x b.log 只解出 b.log" '(( rc == 0 )) && [[ -f o2n/b.log && ! -e o2n/a.txt && ! -e o2n/sub ]]'
run -tf n2.tar sub
check "N2 -t sub lists the directory and what is under it / -t sub 列出目錄與其下成員" \
  '(( rc == 0 )) && [[ $(print -r -- "$(<$TMP/out)" | sort | tr "\n" " ") == "sub/ sub/c.txt " ]]'
rc=0; "$ST" -xO -f n2.tar a.txt > "$TMP/n2o" 2>&1 || rc=$?
check "N2 -xO a.txt prints only a.txt / -xO a.txt 只輸出 a.txt" '(( rc == 0 )) && [[ $(<$TMP/n2o) == a ]]'
run -tf n2.tar nosuch
check "N2 a name not in the archive: exits non-zero and names it / 不在封存中的名稱：非 0 並指出" \
  '(( rc != 0 )) && grep -q "nosuch: not found in archive" "$TMP/out"'
run -tf n2.tar
check "N2 control: no operands lists everything / 對照：無運算元列出全部" \
  '(( rc == 0 )) && [[ $(wc -l < "$TMP/out" | tr -d " ") == 4 ]]'

# --- N3: --no-same-permissions drops setuid/setgid/sticky -----------------------------------
# --- N3：--no-same-permissions 去掉 setuid／setgid／sticky ----------------------------------
if (( windows )); then
  skipc "N3 is POSIX-only / N3 僅適用 POSIX"
else
  RAW_TAR_MODE=0004755 "$RAW" n3.tar file suid.sh x >/dev/null
  mkdir -p o3n; ( umask 027; "$ST" -xf n3.tar -C o3n --no-same-permissions ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "N3 4755 at umask 027 comes out 750, setuid gone / umask 027 下 4755 成為 750" \
    '(( rc == 0 )) && [[ $(fperm o3n/suid.sh) == 750 ]]'
fi

# --- M14: --delete keeps the archive's mode -------------------------------------------------
# --- M14：--delete 保留封存的權限 ------------------------------------------------------------
if (( windows )); then
  skipc "M14 mode check is POSIX-only / M14 權限檢查僅適用 POSIX"
else
  mkdir -p m14; print 1 > m14/one; print 2 > m14/two
  run -cf m14.tar -C m14 one two; chmod 600 m14.tar
  ( umask 022; "$ST" --delete -f m14.tar one ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "M14 --delete on a 0600 archive keeps 0600 / 0600 的封存刪除後仍為 0600" \
    '(( rc == 0 )) && [[ $(perm m14.tar) == 600 ]] && [[ $("$ST" -tf m14.tar) == two ]]'
fi

# --- Low: --zstd-level needs --zstd ----------------------------------------------------------
# --- 低：--zstd-level 需搭配 --zstd ---------------------------------------------------------
# (The unreadable-symlink-target fix has no test: readlink failing right after lstat said
# "link" needs a race. / 讀不出 symlink 目標的修正沒有測試：lstat 判為連結後 readlink 才失敗需要競態。)
mkdir -p lo; print x > lo/x
run -czf lo.tgz --zstd-level 19 lo
check "Low --zstd-level with -z: refused / 搭配 -z 時拒絕" '(( rc != 0 )) && grep -q "needs --zstd" "$TMP/out" && [[ ! -e lo.tgz ]]'
run -c --zstd --zstd-level 19 -f lo.tzst lo
check "Low control: --zstd-level with --zstd works / 對照：搭配 --zstd 可用" '(( rc == 0 ))'

# --- N4: --delete of a directory removes what is under it ------------------------------------
# --- N4：--delete 一個目錄會一併刪掉其下成員 -------------------------------------------------
mkdir -p n4/sub; print a > n4/a.txt; print c > n4/sub/c.txt
run -cf n4.tar -C n4 a.txt sub
run --delete -f n4.tar sub
check "N4 --delete sub removes sub/ and sub/c.txt / 刪除 sub/ 與 sub/c.txt" \
  '(( rc == 0 )) && [[ $("$ST" -tf n4.tar) == a.txt ]]'

# --- N5: -c ../x drops the leading ../ with a warning ----------------------------------------
# --- N5：-c ../x 去掉開頭的 ../ 並警告 -------------------------------------------------------
mkdir -p n5/w; print x > n5/x.txt
( cd n5/w && "$ST" -cf ../n5.tar ../x.txt ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "N5 -c ../x.txt stores x.txt / 存成 x.txt" '(( rc == 0 )) && [[ $("$ST" -tf n5/n5.tar) == x.txt ]]'
check "N5 says it removed ../ / 說明去掉了 ../" 'grep -q "removing leading .\.\./" "$TMP/out"'
mkdir -p o5n; run -xf n5/n5.tar -C o5n
check "N5 the archive extracts with this tool / 本工具能解出" '(( rc == 0 )) && [[ -f o5n/x.txt ]]'
run --help
check "N5 --help no longer says -x refuses absolute paths / --help 不再說拒絕絕對路徑" \
  '! grep -q "refuses absolute paths" "$TMP/out" && grep -q "strips a leading" "$TMP/out"'

# --- Low: -u compares to the nanosecond ------------------------------------------------------
# --- 低：-u 比較到奈秒 -----------------------------------------------------------------------
if (( windows )); then
  skipc "Low -u nanoseconds: touch -t with a fraction is POSIX here / -u 奈秒：此處以 POSIX touch 設定"
else
  # macOS and GNU touch both take -d YYYY-MM-DDThh:mm:SS.frac. / macOS 與 GNU touch 都接受這個 -d 格式。
  mkdir -p lu; print 1 > lu/f
  if ! touch -d 2020-01-01T00:00:10.100000000 lu/f 2>"$TMP/touch.err"; then
    skipc "Low -u nanoseconds: this touch cannot set a fraction / 此 touch 設不了小數秒"
  else
    run -cf lu.tar lu/f
    run -uf lu.tar lu/f
    check "Low control: -u with nothing newer adds nothing / 對照：沒有更新者不加入" \
      '(( rc == 0 )) && [[ $("$ST" -tf lu.tar | grep -c "^lu/f$") == 1 ]]'
    touch -d 2020-01-01T00:00:10.900000000 lu/f
    run -uf lu.tar lu/f
    check "Low -u re-adds a file 0.8 s newer within the same second / 同一秒內較新 0.8 秒會重新加入" \
      '(( rc == 0 )) && [[ $("$ST" -tf lu.tar | grep -c "^lu/f$") == 2 ]]'
  fi
fi

# --- Low: control bytes in a member name are escaped when listed -----------------------------
# --- 低：列出時跳脫成員名稱中的控制字元 -------------------------------------------------------
"$RAW" lc.tar file "$(printf 'a\033[2Jb')" x >/dev/null
run -tf lc.tar
check "Low an ESC in a name lists as \\033 / 名稱中的 ESC 列為 \\033" \
  '(( rc == 0 )) && grep -qxF "a\\033[2Jb" "$TMP/out" && ! grep -q "$(printf "\033")" "$TMP/out"'

# --- Low: -c --zip with 60000 operands does not overflow the stack ---------------------------
# --- 低：-c --zip 給 60000 個運算元不會堆疊溢位 ----------------------------------------------
# Windows caps a command line at 32767 characters, so the shell refuses before swift_tar runs.
# Windows 命令列上限 32767 字元，shell 在 swift_tar 執行前就拒絕。
if (( windows )); then
  skipc "Low 60000 operands: Windows command lines cannot hold them / Windows 命令列放不下"
else
  mkdir -p lz
  ( cd lz && for i in {1..60000}; do : > f$i; done )
  ( cd lz && "$ST" -c --zip -f ../lz.zip f{1..60000} ) >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "Low -c --zip with 60000 operands: exits 0 (0.1.4: SIGSEGV) / 60000 個運算元：以 0 結束" '(( rc == 0 ))'
  rm -rf lz lz.zip
fi

# --- Low: --identify --zip opens the file -----------------------------------------------------
# --- 低：--identify --zip 會開檔 ---------------------------------------------------------------
print "not a zip" > notzip.bin
run --identify --zip -f notzip.bin
check "Low --identify --zip on a text file does not say zip / 對文字檔不回答 zip" '! grep -q ": zip$" "$TMP/out"'

# --- Low: a time before 1970 is carried in pax, not clamped to 1970 ---------------------------
# --- 低：1970 年以前的時間以 pax 帶出，不夾成 1970 ----------------------------------------------
if (( windows )); then
  skipc "Low pre-1970 mtime: POSIX writer path / 1970 前的 mtime：POSIX 寫入路徑"
else
  # The exact mtime, seconds and nanoseconds, as this platform's stat prints it.
  # 精確的 mtime（秒與奈秒），以本平台 stat 的格式。
  if [[ $(uname -s) == Darwin ]]; then mt() { stat -f %Fm -- "$1" }; else mt() { stat -c %.9Y -- "$1" }; fi
  mkdir -p l70; print x > l70/old; mkdir -p l70/olddir
  # macOS and GNU touch take a fraction; busybox 1.37 takes neither the "T" nor a fraction,
  # only "1960-06-15 12:00:00" (whole seconds). A touch that takes no form SKIPs the case
  # rather than ending the test under set -e (LinuxCS guest, 2026-10-31).
  # macOS 與 GNU touch 接受小數；busybox 1.37 兩者都不接受，只接受「1960-06-15 12:00:00」
  # （整秒）。三種寫法都不接受的 touch 讓此案例 SKIP，而不是在 set -e 下結束整支測試
  #（LinuxCS guest，2026-10-31）。
  l70ok=0
  if touch -d 1960-06-15T12:00:00.250000000 l70/old 2>"$TMP/touch.err" \
     || touch -d '1960-06-15 12:00:00' l70/old 2>"$TMP/touch.err"; then
    touch -t 195001010000 l70/olddir 2>"$TMP/touch.err" && l70ok=1
  fi
fi
if (( ! windows )) && (( ! l70ok )); then
  skipc "Low pre-1970 mtime: this touch cannot set a 1960 date / 此 touch 設不了 1960 年的日期"
elif (( ! windows )); then
  run -cf l70.tar l70/old l70/olddir
  mkdir -p o70; run -xf l70.tar -C o70
  check "Low a 1960 file round-trips to the nanosecond (0.1.4: 1970) / 1960 年的檔案逐奈秒往返" \
    '(( rc == 0 )) && [[ $(mt o70/l70/old) == $(mt l70/old) ]]'
  check "Low a 1950 directory round-trips / 1950 年的目錄往返" \
    '[[ $(mt o70/l70/olddir) == $(mt l70/olddir) ]]'
  # GNU tar's own format writes it as a negative base-256 field, not pax.
  # GNU tar 自己的格式以負的 base-256 欄位寫出，不是 pax。
  gnutar=""; for t in gtar tar; do command -v $t >/dev/null && $t --version 2>&1 | grep -q 'GNU tar' && { gnutar=$t; break }; done
  if [[ -z $gnutar ]]; then
    skipc "Low pre-1970 base-256: no GNU tar / 沒有 GNU tar"
  else
    $gnutar --format=gnu -cf l70g.tar l70/olddir 2>"$TMP/gtar.err"
    mkdir -p o70g; run -xf l70g.tar -C o70g
    check "Low a GNU base-256 1950 time is restored / GNU base-256 的 1950 年時間被還原" \
      '(( rc == 0 )) && [[ $(mt o70g/l70/olddir) == $(mt l70/olddir) ]]'
  fi
fi

# --- Low: a file that shrinks while -c --zip reads it is reported -------------------------
# --- 低：-c --zip 讀取中縮小的檔案會被回報 ---------------------------------------------------
# 40 files of 6 MiB are truncated to 0 bytes 80 ms into the run (the threaded path), then one
# 400 MiB file with -n 1 at 150 ms (the single path, which pads with zeros). If the run already
# finished, every member is still whole and the case is SKIPped, not failed. 0.1.4 said nothing
# and exited 0 on both.
# 40 個 6 MiB 的檔案在執行 80 ms 時被截成 0 位元組（多執行緒路徑），再以 -n 1 對一個 400 MiB 的
# 檔案在 150 ms 時截斷（單執行緒路徑，以零補齊）。若執行已先結束，每個成員都完整，該案例 SKIP
# 而不判失敗。0.1.4 兩者皆不作聲並以 0 結束。
if (( windows )) || ! command -v unzip >/dev/null; then
  skipc "Low ZIP shrink: needs POSIX and unzip / ZIP 縮小：需要 POSIX 與 unzip"
else
  zmodload zsh/zselect
  zshrink() {  # <label> <zip> <wait cs> <files...>; then the swift_tar args come from $zargs
    local label=$1 zip=$2 cs=$3; shift 3
    rm -f "$zip"
    "$ST" "${zargs[@]}" -f "$zip" "$@" >"$TMP/zs.out" 2>&1 &
    local pid=$! alive=0 zs=0
    # zselect with no fds returns 1 when the timeout passes; that is the expected result.
    # 沒有 fd 的 zselect 在逾時時回傳 1，那正是預期的結果。
    zselect -t $cs || zs=$?
    (( zs == 0 || zs == 1 )) || { print -u2 "zselect failed ($zs)"; exit 1 }
    # Still running at the moment of truncation? Otherwise nothing shrank under it.
    # 截斷那一刻它還在跑嗎？否則沒有東西在它讀取時縮小。
    kill -0 $pid 2>"$TMP/kill.err" && alive=1
    local f; for f in "$@"; do : > "$f"; done
    rc=0; wait $pid || rc=$?
    if (( ! alive )); then
      skipc "Low ZIP shrink ($label): the run finished before the truncation / 執行在截斷前就結束"
      return
    fi
    check "Low ZIP shrink ($label): reported, exits non-zero, archive intact / 回報、非 0、封存完好" \
      '(( rc != 0 )) && grep -q "shrank" "$TMP/zs.out" && unzip -tq "$zip" >/dev/null'
  }
  mkdir -p zsd
  for i in {1..40}; do dd if=/dev/urandom of=zsd/f$i bs=1048576 count=6 2>"$TMP/dd.err"; done
  zargs=(-c --zip); zshrink threaded zs1.zip 8 zsd/f{1..40}
  dd if=/dev/urandom of=zsd/big bs=1048576 count=400 2>"$TMP/dd.err"
  zargs=(-c --zip -n 1); zshrink single zs2.zip 15 zsd/big
  rm -rf zsd zs1.zip zs2.zip
fi

print -r -- "PASS: $pass  FAIL: $fail  SKIP: $skip"
(( fail == 0 ))
