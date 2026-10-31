#!/usr/bin/env zsh
# test_dereference.zsh -- -h keeps every member: a link it cannot resolve is stored as a link.
# test_dereference.zsh -- -h 不漏任何成員：解不開的連結改存為連結。
#
#   ./test/test_dereference.zsh                          # release/swift_tar[.exe]
#   ST=/path/to/swift_tar ./test/test_dereference.zsh    # a specific binary
#
# Until 2026-10-22, three `-h` situations reported a skip and then dropped the member from the
# archive entirely: a dangling link, a link with an unstattable target, and a link forming a
# cycle. Each left an archive that looked complete and exited 0. All three now store the link
# itself -- the one thing -h is allowed to fail at is dereferencing, not keeping the name. The
# fourth case here is the opposite and must STAY a skip: a directory reached without a link
# whose identity is already on the recursion stack, which a self-referencing junction produces
# on Windows. There is no link to store there, and its content is already in the archive.
# 2026-10-22 之前，`-h` 有三種情形會回報略過、然後把成員從封存中整個丟掉：斷掉的連結、目標
# stat 不到的連結、以及形成迴圈的連結。每一種都留下一個看起來完整、並以 0 結束的封存。三者
# 現在都改存連結本身——-h 唯一被允許失敗的是「解參照」，不是「把名稱留在封存裡」。此處第四個
# 案例相反，必須「維持」略過：不經連結抵達、而識別碼已在遞迴堆疊上的目錄，在 Windows 上由
# 自我指涉的 junction 產生。那裡沒有連結可存，其內容也早已在封存裡。
#
# Symlink creation is the reason this script probes before it asserts. On Git Bash with MSYS
# unset, `ln -s` to a missing target FAILS and `ln -s` to an existing one silently makes a COPY
# (measured 2026-10-22) -- so a test that just called `ln -s` would pass while testing nothing.
# Windows needs MSYS=winsymlinks:nativestrict, and that needs Developer Mode or admin, so the
# cases SKIP rather than fail where links cannot be made.
# 本腳本先探測再斷言，原因在於建立 symlink 本身。在 MSYS 未設的 Git Bash 上，`ln -s` 指向缺失
# 目標會「失敗」，指向存在目標則靜默做出「複本」（2026-10-22 實測）——所以只呼叫 `ln -s` 的測試
# 會在什麼都沒測到的情況下通過。Windows 需要 MSYS=winsymlinks:nativestrict，而那需要開發者模式
# 或管理員權限，故在無法建立連結的環境下這些案例以 SKIP 處理而非失敗。
set -euo pipefail

script_path="${0:A}"
if [ "${1:-}" = "--help" ]; then
  sed -n '2,6p' "${script_path}" | sed 's/^# \{0,1\}//'
  exit 0
fi
ROOT="${script_path:h:h}"
case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) IS_WIN=1 ;;
  *) IS_WIN=0 ;;
esac
if [ -z "${ST:-}" ]; then
  if [ "${IS_WIN}" = 1 ]; then ST="${ROOT}/release/swift_tar.exe"; else ST="${ROOT}/release/swift_tar"; fi
fi
[ -x "${ST}" ] || { printf 'error: build first -- missing %s\n' "${ST}" >&2; exit 1; }

pass=0; fail=0; skip=0
ok()   { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
note() { printf 'SKIP: %s\n' "$1"; skip=$((skip + 1)); }

# Tries TMPDIR before the compiled-in /tmp: in Git Bash under some sandboxes /tmp is read-only
# while TMPDIR is fine (measured 2026-10-22), and a failure names every place that was tried.
# 先試 TMPDIR 再試編譯進去的 /tmp：在某些沙箱下的 Git Bash 裡 /tmp 唯讀而 TMPDIR 可用
# （2026-10-22 實測）；失敗時列出每個試過的位置。
#
# CORRECTED 2026-10-22. This comment first claimed that `TMP="$(mktemp -d)"` does not trip
# `set -e`, so a failed mktemp would leave TMP empty and move every fixture to "/<name>", and
# called that measured. It was not measured, and it is false: under `set -e` zsh aborts on a
# failed command substitution in an assignment (rc 1, the next line never runs); only
# `local x=$(...)` masks it. The empty TMP was seen in an interactive Git Bash with no
# `set -e`, and the rest was inference written in the voice of a measurement.
# 2026-10-22 更正。此註解最初宣稱 `TMP="$(mktemp -d)"` 不會觸發 `set -e`，於是 mktemp 失敗時
# TMP 為空、每個測資移到 "/<名稱>"，並稱之為實測。它沒有量過，而且是錯的：在 `set -e` 下，
# 賦值中的命令替換失敗時 zsh 會中止（rc 1，下一行不會執行）；只有 `local x=$(...)` 會蓋掉它。
# 空的 TMP 是在沒有 `set -e` 的互動式 Git Bash 裡看到的，其餘是用實測語氣寫下的推論。
mk_tmp() {
  local base d errs=""
  for base in "${TMPDIR:-}" /tmp; do
    [ -n "${base}" ] || continue
    if d=$(mktemp -d -p "${base}" 2>&1); then printf '%s' "${d}"; return 0; fi
    errs="${errs}  ${base}: ${d}"$'\n'
  done
  printf 'error: no writable temporary directory\n%s' "${errs}" >&2
  return 1
}
TMP="$(mk_tmp)" || exit 1
[ -d "${TMP}" ] && [ -w "${TMP}" ] || { printf 'error: %s is not a writable directory\n' "${TMP}" >&2; exit 1; }
cleanup() {
  # A junction must be removed as a junction; rm -rf would walk through it.
  # junction 必須以 junction 的方式移除；rm -rf 會穿過去。
  if [ "${IS_WIN}" = 1 ] && [ -e "${TMP}/jcyc/d/up" ]; then
    # Tolerated deliberately: cleanup must not mask a test failure by exiting non-zero, and the
    # rm -rf below is the backstop. / 刻意容忍：清理不該以非零退出蓋掉測試結果，下方的 rm -rf
    # 是後援。
    ( cd "${TMP}/jcyc" && cmd.exe //c rmdir "d\\up" ) >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

# A real symlink, or a non-zero return when this environment cannot make one. Verified with
# `[ -L ]` rather than by `ln`'s exit status, because on Git Bash with MSYS unset `ln -s` to an
# EXISTING target returns 0 and silently produces a COPY (measured 2026-10-22) -- a fixture that
# is not a link at all, which every assertion below would then be testing nothing against.
#
# Two Windows routes, because neither alone is enough on this machine:
#   * `ln -s` -- works on POSIX, and under the zsh at scoop/shims/zsh for an EXISTING target,
#     but fails outright for a MISSING one ("No such file or directory") in every winsymlinks
#     mode tried, MSYS= and CYGWIN= alike.
#   * `cmd mklink` -- creates dangling links happily, and zsh recognises the result
#     ([ -L ] true, readlink correct). Paths are RELATIVE with the cwd inherited, never built
#     with cygpath. That zsh ships its OWN msys-2.0.dll (runtime 3.6.11, uname MINGW64_NT) while
#     Git Bash runs 3.6.10: two MSYS2 runtimes on one machine, each with its own "/" root. Its
#     `/tmp` lives inside the zsh install, and `cygpath -m` resolved a temp dir there to
#     `C:/Windows/tmp.XXXX`, so a cygpath-built argument names a path that does not exist and
#     mklink answers "The system cannot find the path specified". Relative paths sidestep the
#     whole root-mapping question. `mklink` needs Developer Mode or admin, so a failure here is
#     an environment limit and the caller skips.
#     (Corrected 2026-10-22: this comment first called it "the Cygwin zsh". It is MSYS --
#     measured with uname and the shipped DLL. 2026-10-22 更正：此處原稱「Cygwin zsh」，實為
#     MSYS，以 uname 與隨附的 DLL 量得。)
#
# 以 `[ -L ]` 驗證而非看 `ln` 的退出碼，因為在 MSYS 未設的 Git Bash 上，`ln -s` 指向「存在」的
# 目標會回傳 0 卻靜默做出「複本」（2026-10-22 實測）——一個根本不是連結的測資，而底下每個斷言
# 就都在對著它什麼也沒測。
#
# Windows 需要兩條途徑，因為這台機器上任一條都不夠：
#   * `ln -s`——在 POSIX 上可行，在 scoop/shims/zsh 的 zsh 下對「存在」的目標可行，但對
#     「缺失」的目標一律失敗（"No such file or directory"），試過的 MSYS= 與 CYGWIN= 各種
#     winsymlinks 模式皆然。
#   * `cmd mklink`——可以直接建出斷鏈，且 zsh 認得其結果（[ -L ] 為真、readlink 正確）。路徑
#     用「相對」並繼承 cwd，絕不用 cygpath 組：那個 zsh 自帶 msys-2.0.dll（runtime 3.6.11），
#     Git Bash 則是 3.6.10——同一台機器上兩份 MSYS2 runtime，各有自己的 "/" 根。它的 `/tmp`
#     位於 zsh 安裝目錄內，而 `cygpath -m` 會把它解到完全不同的根（實測：一個暫存目錄被解成
#     `C:/Windows/tmp.XXXX`），於是以 cygpath 組出的引數指向一個不存在的路徑，mklink 回答
#     「The system cannot find the path specified」。相對路徑完全繞開根映射這個問題。`mklink`
#     需要開發者模式或管理員權限，故此處失敗屬環境限制，呼叫方以 SKIP 處理。
mklink_s() {   # mklink_s <target> <linkpath>
  ln -s "$1" "$2" 2>/dev/null || true
  [ -L "$2" ] && return 0
  rm -f "$2" 2>/dev/null || true
  [ "${IS_WIN}" = 1 ] || return 1
  ( cd "${2:h}" && cmd.exe //c mklink "${2:t}" "$(printf '%s' "$1" | tr '/' '\\')" ) >/dev/null 2>&1 || true
  [ -L "$2" ] && return 0
  ( cd "${2:h}" && cmd.exe //c mklink //D "${2:t}" "$(printf '%s' "$1" | tr '/' '\\')" ) >/dev/null 2>&1 || true
  [ -L "$2" ] || return 1
}
# stderr is dropped deliberately: -t writes a "compression format" line there whatever happens,
# and these two helpers exist to compare the member LIST. Every assertion that cares about
# stderr captures it with 2>&1 at the call site instead.
# 刻意丟掉 stderr：-t 無論成敗都會往那裡寫一行 "compression format"，而這兩個 helper 的用途是
# 比對成員「清單」。在意 stderr 的斷言都在呼叫處以 2>&1 自行擷取。
members() { "${ST}" -tf "$1" 2>/dev/null; }
has()     { members "$1" | grep -qxF "$2"; }

# ---------------------------------------------------------------------
# 1. A dangling link between two plain files: nothing may go missing.
#    夾在兩個普通檔案之間的斷鏈：不得有任何東西遺失。
# ---------------------------------------------------------------------
d="${TMP}/dang"; mkdir -p "${d}"
printf 'A\n' > "${d}/aaa.txt"; printf 'Z\n' > "${d}/zzz.txt"
if ! mklink_s nowhere "${d}/mmm"; then
  note 'dangling link: this environment cannot create symlinks'
else
  rc=0; out="$( cd "${d}" && "${ST}" -c -h -f "${TMP}/dang.tar" . 2>&1 )" || rc=$?
  [ "${rc}" = 0 ] && ok 'dangling link: -c -h exits 0' \
    || bad "dangling link: -c -h exits 0 (got ${rc})"
  # The regression this file exists for: the link's own entry. / 本檔案存在的理由：連結自己的項目。
  has "${TMP}/dang.tar" './mmm' && ok 'dangling link: the link is stored, not dropped' \
    || bad "dangling link: the link is stored, not dropped (members: $(members "${TMP}/dang.tar" | tr '\n' ' '))"
  # The sibling AFTER it, which a walk that aborted would lose. / 它之後的兄弟項目，走訪中止就會遺失。
  has "${TMP}/dang.tar" './zzz.txt' && ok 'dangling link: the sibling after it survives' \
    || bad 'dangling link: the sibling after it survives'
  printf '%s' "${out}" | grep -q 'storing the link itself' \
    && ok 'dangling link: the fallback is reported on stderr' \
    || bad "dangling link: the fallback is reported on stderr (got: ${out})"
  # The target string has to survive too, or the entry is malformed rather than preserved.
  # 目標字串也必須保留，否則該項目是壞的而非被保住。
  mkdir -p "${TMP}/dang_x"
  # Tolerated deliberately: creating a symlink on extract needs Developer Mode or admin on
  # Windows, and failing that is an environment limit, not a defect -- so the `[ -L ]` below
  # decides between asserting and skipping rather than this exit status.
  # 刻意容忍：在 Windows 上解壓時建立 symlink 需要開發者模式或管理員權限，失敗屬環境限制而非
  # 缺陷——故由下方的 `[ -L ]` 決定要斷言還是跳過，而不是看這裡的退出碼。
  "${ST}" -xf "${TMP}/dang.tar" -C "${TMP}/dang_x" >/dev/null 2>&1 || true
  if [ -L "${TMP}/dang_x/mmm" ]; then
    [ "$(readlink "${TMP}/dang_x/mmm")" = nowhere ] \
      && ok 'dangling link: the stored target is intact' \
      || bad "dangling link: the stored target is intact (got '$(readlink "${TMP}/dang_x/mmm")')"
  else
    note 'dangling link: target check needs symlink creation on extract'
  fi
fi

# ---------------------------------------------------------------------
# 2. A link forming a cycle: not expanded, but the entry is kept.
#    形成迴圈的連結：不展開，但保留項目。
# ---------------------------------------------------------------------
c="${TMP}/cyc"; mkdir -p "${c}/d"
printf 'T\n' > "${c}/top.txt"
if ! ( cd "${c}/d" && mklink_s .. up ); then
  note 'cycle: this environment cannot create symlinks'
else
  rc=0; out="$( cd "${c}" && "${ST}" -c -h -f "${TMP}/cyc.tar" . 2>&1 )" || rc=$?
  [ "${rc}" = 0 ] && ok 'cycle: -c -h exits 0' || bad "cycle: -c -h exits 0 (got ${rc})"
  has "${TMP}/cyc.tar" './d/up' && ok 'cycle: the link is stored, not dropped' \
    || bad "cycle: the link is stored, not dropped (members: $(members "${TMP}/cyc.tar" | tr '\n' ' '))"
  # Bounded, i.e. the cycle really was detected. GNU tar 1.35 produces thousands here.
  # 有界，也就是迴圈真的被偵測到。GNU tar 1.35 在此會產出數千個成員。
  n=$(members "${TMP}/cyc.tar" | wc -l | tr -d ' ')
  [ "${n}" -le 8 ] && ok "cycle: the walk stays bounded (${n} members)" \
    || bad "cycle: the walk stays bounded (got ${n} members)"
  printf '%s' "${out}" | grep -q 'would loop here' \
    && ok 'cycle: it is reported as a loop' || bad 'cycle: it is reported as a loop'
fi

# ---------------------------------------------------------------------
# 3. A directory that cannot be listed: its entry stays, its contents are
#    reported, the walk continues, and the run exits 1. POSIX only -- Windows does not
#    enforce mode bits against the owner, and an ACL deny blocks the stat
#    too, which is a different (documented) failure.
#    列不出內容的目錄：項目保留、內容被回報、走訪繼續，最後以 1 結束。僅 POSIX——Windows 不對
#    擁有者強制 mode 位元，而 ACL 拒絕會連 stat 一起擋掉，那是另一種（已文件化的）失敗。
# ---------------------------------------------------------------------
if [ "${IS_WIN}" = 1 ]; then
  note 'unlistable directory: Windows does not enforce POSIX mode bits against the owner'
elif [ "$(id -u)" = 0 ]; then
  note 'unlistable directory: running as root, which is not refused by mode bits'
else
  u="${TMP}/unl"; mkdir -p "${u}/mmm"
  printf 'A\n' > "${u}/aaa.txt"; printf 'Z\n' > "${u}/zzz.txt"
  printf 'lost\n' > "${u}/mmm/inner.txt"
  chmod 000 "${u}/mmm"
  rc=0; out="$( cd "${u}" && "${ST}" -c -h -f "${TMP}/unl.tar" . 2>&1 )" || rc=$?
  chmod 755 "${u}/mmm"
  has "${TMP}/unl.tar" './mmm/' && ok 'unlistable directory: its own entry is stored' \
    || bad 'unlistable directory: its own entry is stored'
  has "${TMP}/unl.tar" './zzz.txt' && ok 'unlistable directory: the sibling after it survives' \
    || bad 'unlistable directory: the sibling after it survives'
  members "${TMP}/unl.tar" | grep -q 'inner.txt' \
    && bad 'unlistable directory: the unreadable content is absent' \
    || ok 'unlistable directory: the unreadable content is absent'
  # The whole point: it is no longer silent, and the run exits 1 as bsdtar's does.
  # 重點所在：它不再沉默，而且與 bsdtar 一樣以 1 結束。
  printf '%s' "${out}" | grep -q 'mmm/: cannot read directory' \
    && ok 'unlistable directory: the failure is reported, not swallowed' \
    || bad "unlistable directory: the failure is reported, not swallowed (got: ${out})"
  [ "${rc}" = 1 ] && ok 'unlistable directory: exit 1' || bad "unlistable directory: exit 1 (got ${rc})"
fi

# ---------------------------------------------------------------------
# 4. A self-referencing junction: the cycle check must still SKIP, and must
#    not invent a symlink entry for a directory. Windows only -- NT traverses
#    a junction, which is what makes this shape reachable at all.
#    自我指涉的 junction：迴圈檢查必須「仍然」略過，且不得為一個目錄憑空造出
#    symlink 項目。僅 Windows——NT 會穿過 junction，這正是此形狀得以存在的原因。
# ---------------------------------------------------------------------
if [ "${IS_WIN}" != 1 ]; then
  note 'self-referencing junction: Windows only'
else
  j="${TMP}/jcyc"; mkdir -p "${j}/d"
  printf 'F\n' > "${j}/d/f.txt"; printf 'T\n' > "${j}/top.txt"
  # Relative, cwd inherited -- see mklink_s for why cygpath is not used here.
  # 相對路徑、繼承 cwd——為何不用 cygpath，見 mklink_s。
  if ! ( cd "${j}" && cmd.exe //c mklink //J "d\\up" "." ) >/dev/null 2>&1 || [ ! -e "${j}/d/up" ]; then
    note 'self-referencing junction: mklink /J failed'
  else
    rc=0; out="$( cd "${j}" && "${ST}" -c -h -f "${TMP}/jcyc.tar" . 2>&1 )" || rc=$?
    [ "${rc}" = 0 ] && ok 'junction cycle: -c -h exits 0' || bad "junction cycle: -c -h exits 0 (got ${rc})"
    n=$(members "${TMP}/jcyc.tar" | wc -l | tr -d ' ')
    [ "${n}" -le 10 ] && ok "junction cycle: the walk stays bounded (${n} members)" \
      || bad "junction cycle: the walk stays bounded (got ${n} members)"
    printf '%s' "${out}" | grep -q 'would loop here' \
      && ok 'junction cycle: it is reported as a loop' || bad 'junction cycle: it is reported as a loop'
    # The directory behind the junction is already archived under its real name, so the
    # skipped entry costs no content. / junction 背後的目錄已以真實名稱入檔，故略過不損失內容。
    has "${TMP}/jcyc.tar" './d/f.txt' \
      && ok 'junction cycle: the real directory is archived under its own name' \
      || bad 'junction cycle: the real directory is archived under its own name'
    printf '%s' "${out}" | grep -q 'storing the link itself' \
      && bad 'junction cycle: a directory is NOT stored as a link' \
      || ok 'junction cycle: a directory is NOT stored as a link'
    # Without -h: a junction is walked as a directory, and 0.1.4 recursed forever here
    # (2026-10-31 review M12). / 不加 -h：junction 被當成目錄走進去，0.1.4 在此無限遞迴（審查 M12）。
    rc=0; out="$( cd "${j}" && "${ST}" -c -f "${TMP}/jcyc2.tar" . 2>&1 )" || rc=$?
    [ "${rc}" = 0 ] && ok 'junction cycle without -h: exits 0' || bad "junction cycle without -h: exits 0 (got ${rc})"
    n=$(members "${TMP}/jcyc2.tar" | wc -l | tr -d ' ')
    [ "${n}" -le 10 ] && ok "junction cycle without -h: the walk stays bounded (${n} members)" \
      || bad "junction cycle without -h: the walk stays bounded (got ${n} members)"
    printf '%s' "${out}" | grep -q 'would loop here' \
      && ok 'junction cycle without -h: it is reported as a loop' \
      || bad 'junction cycle without -h: it is reported as a loop'
  fi
fi

# ---------------------------------------------------------------------
# 5. An LX (WSL/MSYS) link to a DIRECTORY. NT cannot traverse one, so -h has
#    to resolve it and read through the resolved path while still naming the
#    member after the link. Needs wsl.exe to create the link.
#    指向「目錄」的 LX（WSL／MSYS）連結。NT 穿不過去，故 -h 必須自行解析並經由
#    解析後的路徑讀取，同時仍以連結命名成員。建立該連結需要 wsl.exe。
# ---------------------------------------------------------------------
if [ "${IS_WIN}" != 1 ] || ! command -v wsl.exe >/dev/null 2>&1; then
  note 'LX link to a directory: needs Windows with wsl.exe'
else
  l="${TMP}/lx"; mkdir -p "${l}"
  # wsl.exe translates the inherited cwd itself, so no path is passed and cygpath stays out of
  # it -- see mklink_s for what cygpath does to that zsh's temp path. MSYS2_ARG_CONV_EXCL is
  # still required: without it the MSYS runtime rewrites POSIX-looking arguments before
  # wsl.exe sees them.
  # wsl.exe 會自行轉換繼承而來的 cwd，故不傳任何路徑、也完全不碰 cygpath——cygpath 會對
  # 那個 zsh 的暫存路徑做什麼，見 mklink_s。MSYS2_ARG_CONV_EXCL 仍然必要：少了它，MSYS
  # runtime 會在 wsl.exe 看到引數之前就改寫看起來像 POSIX 路徑的部分。
  if ! ( cd "${l}" && MSYS2_ARG_CONV_EXCL='*' wsl.exe -- bash -c 'ln -s realdir dlink && mkdir realdir && printf "inside\n" > realdir/f.txt' ) >/dev/null 2>&1 \
     || [ ! -e "${l}/dlink" ]; then
    note 'LX link to a directory: could not create the link through wsl.exe'
  else
    rc=0; ( cd "${l}" && "${ST}" -c -h -f "${TMP}/lx.tar" . ) >/dev/null 2>&1 || rc=$?
    [ "${rc}" = 0 ] && ok 'LX directory: -c -h exits 0' || bad "LX directory: -c -h exits 0 (got ${rc})"
    has "${TMP}/lx.tar" './dlink/f.txt' \
      && ok 'LX directory: content is stored under the LINK name' \
      || bad "LX directory: content is stored under the LINK name (members: $(members "${TMP}/lx.tar" | tr '\n' ' '))"
    has "${TMP}/lx.tar" './realdir/f.txt' \
      && ok 'LX directory: content is also stored under the real name' \
      || bad 'LX directory: content is also stored under the real name'
    # The bytes, not just the name -- reading through the link is the part that was broken.
    # 要位元組而非只要名稱——經由連結讀取才是當初壞掉的部分。
    mkdir -p "${TMP}/lx_x"
    # Tolerated deliberately: this archive holds no symlink members (the LX link was resolved),
    # so a non-zero here would be a real defect -- but it is the `[ -f ]` and the byte
    # comparison below that say so, with a FAIL rather than an abort that hides the reason.
    # 刻意容忍：此封存不含 symlink 成員（LX 連結已被解析），故此處非零確實是缺陷——但說出這件事
    # 的是下方的 `[ -f ]` 與位元組比對，它們給出 FAIL，而不是一個會藏住原因的中止。
    "${ST}" -xf "${TMP}/lx.tar" -C "${TMP}/lx_x" >/dev/null 2>&1 || true
    if [ -f "${TMP}/lx_x/dlink/f.txt" ]; then
      [ "$(cat "${TMP}/lx_x/dlink/f.txt")" = inside ] \
        && ok 'LX directory: the extracted bytes are correct' \
        || bad 'LX directory: the extracted bytes are correct'
    else
      bad 'LX directory: dlink/f.txt did not extract'
    fi
  fi
fi

printf -- '-----------------------------------------\n'
printf 'PASS: %s  FAIL: %s  SKIP: %s\n' "${pass}" "${fail}" "${skip}"
[ "${fail}" = 0 ]
