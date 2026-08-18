#!/usr/bin/env zsh
# =====================================================================
# tar_interop_matrix.zsh -- swift_tar against every tar on this machine.
# tar_interop_matrix.zsh -- 以本機每一個 tar 實作交叉驗證 swift_tar。
#
# bsdtar_compat.zsh deliberately refuses a reference that does not report
# itself as bsdtar, so it cannot answer "does GNU tar read this too". This
# script asks the wider question: for every tar implementation present, can it
# read what swift_tar writes, and can swift_tar read what it writes.
# bsdtar_compat.zsh 刻意拒絕非 bsdtar 的參照工具，故無法回答「GNU tar 是否也讀得
# 懂」。本腳本問的是更廣的問題：對於現場存在的每一個 tar 實作，它能否讀懂
# swift_tar 寫出的封存，而 swift_tar 又能否讀懂它寫出的封存。
#
# The same file runs on macOS, Windows/MSYS, a Linux VM and WSL, and writes
# tar_interop_matrix_output-<platform>.txt. Nothing here is platform-specific
# except which tools happen to exist, and a tool that is absent is reported as
# absent -- never silently skipped into a pass.
# 同一支檔案可在 macOS、Windows/MSYS、Linux VM 與 WSL 上執行，並寫出
# tar_interop_matrix_output-<平台>.txt。除了現場有哪些工具之外，此處沒有任何平台
# 專屬邏輯；工具不存在時會如實回報為不存在，絕不靜默跳過並計為通過。
#
# Usage / 用法:
#   verifications/tar_interop_matrix.zsh              # verify only / 僅驗證
#   verifications/tar_interop_matrix.zsh --record     # also write the record
#
# Exit / 結束碼:  0 all present tools interoperate   1 an incompatibility
# =====================================================================
set -uo pipefail

HERE="${0:A:h}"
REPO="${HERE:h}"
cd "$REPO"

RECORD=0
for arg in "$@"; do
    case "$arg" in
        --record) RECORD=1 ;;
        *) print -ru2 -- "usage: $0 [--record]"; exit 2 ;;
    esac
done

. "$REPO/platform.zsh"
PLATFORM=$(swift_tar_platform)

case "$(uname -s)" in
    CYGWIN*|MSYS*|MINGW*) ST="${ST:-$REPO/release/swift_tar.exe}" ;;
    *)                    ST="${ST:-$REPO/release/swift_tar}" ;;
esac
[[ -x "$ST" ]] || { print -ru2 -- "[Error] no swift_tar at $ST — build first / 請先建置"; exit 2 }

# ---------------------------------------------------------------------
# Which tars are here. Each candidate is identified by what it says about
# itself, not by its filename: on macOS `tar` is bsdtar, on most Linux it is
# GNU tar, and on Windows `tar.exe` is bsdtar while an MSYS `tar` is GNU. A
# matrix keyed on filenames would mislabel every row.
# 現場有哪些 tar。每個候選者以其自我描述辨識，而非以檔名：macOS 的 `tar` 是
# bsdtar，多數 Linux 的是 GNU tar，而 Windows 的 `tar.exe` 是 bsdtar、MSYS 的
# `tar` 則是 GNU。以檔名為鍵的矩陣會把每一列都標錯。
# ---------------------------------------------------------------------
typeset -a REF_PATH REF_KIND REF_VER
probe() {
    local p="$1" v kind
    [[ -x "$p" ]] || return 1
    v=$("$p" --version 2>&1 | head -1) || return 1
    # Strip a trailing CR. The Windows-native bsdtar ends its --version line with
    # CRLF, and that CR travelled into the recorded file, leaving one stray CR in
    # an otherwise-LF repository -- and coming back on every --record, so cleaning
    # the file by hand fixed nothing. It also makes the version string unequal to
    # the same version captured elsewhere, which would defeat the duplicate check
    # just below.
    # 去除結尾的 CR。Windows 內建的 bsdtar 其 --version 行以 CRLF 結尾，該 CR 會一路
    # 進入紀錄檔，在一個其餘皆為 LF 的程式庫裡留下一個孤立的 CR——且每次 --record 都會
    # 再回來，故手動清理該檔毫無作用。它同時也會讓此版本字串與他處擷取的同一版本不相等，
    # 使下方的重複檢查失效。
    v=${v%$'\r'}
    case "$v" in
        *"bsdtar"*)   kind=bsdtar ;;
        *"GNU tar"*)  kind=gnutar ;;
        *)            return 1 ;;
    esac
    # Skip a path that is the same implementation AND version we already have,
    # so /usr/bin/tar and a symlink to it do not become two matrix rows.
    # 若某路徑與既有項目的實作與版本皆相同則略過，以免 /usr/bin/tar 與指向它的
    # 符號連結變成矩陣中的兩列。
    local i
    for ((i = 1; i <= ${#REF_KIND}; i++)); do
        [[ "${REF_KIND[i]}" == "$kind" && "${REF_VER[i]}" == "$v" ]] && return 1
    done
    REF_PATH+=("$p"); REF_KIND+=("$kind"); REF_VER+=("$v")
    return 0
}

for cand in /usr/bin/tar /usr/bin/bsdtar /bin/tar \
            /c/Windows/System32/tar.exe \
            "${commands[tar]:-}" "${commands[gtar]:-}" "${commands[bsdtar]:-}" \
            /opt/homebrew/bin/gtar /usr/local/bin/gtar \
            /opt/homebrew/opt/gnu-tar/libexec/gnubin/tar; do
    [[ -n "$cand" ]] && probe "$cand"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tarmatrix.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
STAGE="$TMP/record.txt"

pass=0; fail=0; skip=0
emit() { print -r -- "$1"; print -r -- "$1" >> "$STAGE" }
# These go through emit, like the section headers do. They used to print only to
# stdout, so the recorded file carried the headers, the reference-tool versions
# and the final tally -- with three empty sections between them. A record that
# says "PASS: 12" without naming the twelve cannot be compared against the next
# run: it cannot show which cell changed, only that the count did.
# 這三者與區段標題一樣改走 emit。它們原本只印到 stdout，故紀錄檔裡有標題、參照工具版本
# 與最終統計，中間卻是三個空區段。一份只寫「PASS: 12」而不列出那十二項的紀錄，無法與
# 下一次執行比對：它顯示不出哪一格變了，只顯示得出數字變了。
ok()   { emit "  PASS  $1"; pass=$((pass+1)) }
bad()  { emit "  FAIL  $1"; fail=$((fail+1)) }
skipc(){ emit "  SKIP  $1"; skip=$((skip+1)) }

# ---------------------------------------------------------------------
# The corpus. Every entry here is a shape that has broken something at least
# once: a non-ASCII name, a symlink, a hardlink pair, a nested path, and a file
# large enough to cross a chunk boundary rather than three bytes of "hello".
# 語料。此處每一項都是至少曾弄壞過某個環節的形狀：非 ASCII 名稱、符號連結、
# 硬連結配對、巢狀路徑，以及一個大到足以跨越分塊邊界的檔案，而非三個位元組的
# "hello"。
# ---------------------------------------------------------------------
SRC="$TMP/src"
mkdir -p "$SRC/nested/deeper"
print -n 'plain ascii' > "$SRC/a.txt"
print -n 'x' > "$SRC/中文檔名.txt"
print -n 'y' > "$SRC/nested/deeper/deep.txt"
# 5 MiB crosses the 4 MiB chunk boundary the parallel path splits on.
# 5 MiB 會跨越平行路徑所依據的 4 MiB 分塊邊界。
dd if=/dev/urandom of="$SRC/big.bin" bs=1048576 count=5 2>/dev/null
ln -s a.txt "$SRC/link_to_a"
print -n 'hard' > "$SRC/hard1.txt"
ln "$SRC/hard1.txt" "$SRC/hard2.txt" 2>/dev/null || true

tree_sum() { ( cd "$1" && find . | LC_ALL=C sort | while read -r p; do
        if [[ -L "$p" ]]; then print -r -- "$p L $(readlink "$p")"
        elif [[ -d "$p" ]]; then print -r -- "$p D"
        else print -r -- "$p F $(shasum -a 256 "$p" | cut -d' ' -f1)"
        fi
    done | shasum -a 256 | cut -d' ' -f1 ) }
WANT=$(tree_sum "$SRC")

emit "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
emit "[Info] platform: $PLATFORM"
emit "[Info] host: $(uname -srm)"
emit "[Info] swift_tar: $("$ST" --version 2>/dev/null | head -1)"
emit "[Info] corpus digest: $WANT"
emit ""
if (( ${#REF_PATH} == 0 )); then
    emit "[Error] no tar implementation found to compare against / 找不到任何可供比對的 tar 實作"
    exit 2
fi
emit "== reference tar implementations found / 現場找到的參照實作 =="
for ((i = 1; i <= ${#REF_PATH}; i++)); do
    emit "  ${REF_KIND[i]}  ${REF_PATH[i]}"
    emit "         ${REF_VER[i]}"
done
emit ""

# ---------------------------------------------------------------------
# Both directions per codec. Reading is what interoperability means in
# practice: an archive nobody else can open is not a tar, and an archive
# swift_tar cannot open is not interoperable either.
# 每種壓縮引擎都測兩個方向。互通在實務上的意義就是「讀得懂」：別人打不開的封存
# 不算 tar，而 swift_tar 打不開的封存同樣不算互通。
# ---------------------------------------------------------------------
emit "== swift_tar writes, each reference reads / swift_tar 寫入，各參照讀取 =="
for codec in plain gzip; do
    case $codec in
        plain) cflag=(); ext=tar ;;
        gzip)  cflag=(--gzip); ext=tar.gz ;;
    esac
    arc="$TMP/st.$ext"
    if ! "$ST" -c "${cflag[@]}" -f "$arc" -C "$TMP" src >/dev/null 2>&1; then
        bad "swift_tar -c $codec (could not even create)"
        continue
    fi
    for ((i = 1; i <= ${#REF_PATH}; i++)); do
        ref="${REF_PATH[i]}"; kind="${REF_KIND[i]}"
        out="$TMP/out.$kind.$codec"; rm -rf "$out"; mkdir -p "$out"
        if "$ref" -xf "$arc" -C "$out" >/dev/null 2>&1 \
           && [[ "$(tree_sum "$out/src")" == "$WANT" ]]; then
            ok "$kind reads swift_tar's $codec archive"
        else
            bad "$kind reads swift_tar's $codec archive"
        fi
    done
done

emit ""
emit "== each reference writes, swift_tar reads / 各參照寫入，swift_tar 讀取 =="
for ((i = 1; i <= ${#REF_PATH}; i++)); do
    ref="${REF_PATH[i]}"; kind="${REF_KIND[i]}"
    for codec in plain gzip; do
        case $codec in
            plain) rflag=(-cf); ext=tar ;;
            gzip)  rflag=(-czf); ext=tar.gz ;;
        esac
        arc="$TMP/ref.$kind.$ext"
        # COPYFILE_DISABLE keeps macOS out of the measurement. Without it,
        # bsdtar on macOS writes an AppleDouble `._name` member beside every
        # entry to carry extended attributes, then hides those members again on
        # its own read and folds them back into xattrs. Nothing else does: GNU
        # tar 1.35 lists them, extracts them as ordinary files, and warns
        # "Ignoring unknown extended header keyword LIBARCHIVE.xattr.com.apple
        # .provenance" -- and swift_tar behaves exactly as GNU tar does. Left
        # on, this row would report a swift_tar incompatibility that is really
        # an Apple convention only its own tar round-trips, and the matrix would
        # be measuring xattr policy instead of tar semantics.
        # COPYFILE_DISABLE 讓 macOS 的特性不進入量測。若不設定，macOS 的 bsdtar 會
        # 在每個項目旁寫入一個 AppleDouble 的 `._名稱` 成員以攜帶延伸屬性，並在自己
        # 讀取時再次隱藏它們、還原為 xattr。其他工具都不這麼做：GNU tar 1.35 會列出
        # 它們、將其解為一般檔案，並警告「Ignoring unknown extended header keyword
        # LIBARCHIVE.xattr.com.apple.provenance」——而 swift_tar 的行為與 GNU tar
        # 完全相同。若不設定，本列會回報一個實為「只有 Apple 自家 tar 能往返的慣例」
        # 的 swift_tar 不相容，且整個矩陣量到的會是 xattr 政策而非 tar 語意。
        if ! ( cd "$TMP" && COPYFILE_DISABLE=1 "$ref" "${rflag[@]}" "$arc" src ) >/dev/null 2>&1; then
            skipc "$kind could not create a $codec archive here"
            continue
        fi
        out="$TMP/back.$kind.$codec"; rm -rf "$out"; mkdir -p "$out"
        if "$ST" -x -f "$arc" -C "$out" >/dev/null 2>&1 \
           && [[ "$(tree_sum "$out/src")" == "$WANT" ]]; then
            ok "swift_tar reads $kind's $codec archive"
        else
            bad "swift_tar reads $kind's $codec archive"
        fi
    done
done

# ---------------------------------------------------------------------
# Listings must agree on names. A tree that extracts identically can still be
# listed under different spellings -- a doubled separator or a mangled
# non-ASCII name shows up here and nowhere else.
# 列表所呈現的名稱必須一致。解出後內容相同的樹，其列出的名稱寫法仍可能不同——
# 加倍的分隔符或損壞的非 ASCII 名稱只會在這裡現形，別處看不到。
# ---------------------------------------------------------------------
emit ""
emit "== listings agree on names / 列表名稱一致 =="
arc="$TMP/st.tar"
st_list="$TMP/list.st"
"$ST" -t -f "$arc" 2>/dev/null | LC_ALL=C sort > "$st_list"
for ((i = 1; i <= ${#REF_PATH}; i++)); do
    ref="${REF_PATH[i]}"; kind="${REF_KIND[i]}"
    ref_list="$TMP/list.$kind"
    "$ref" -tf "$arc" 2>/dev/null | sed 's#/$##' | LC_ALL=C sort > "$ref_list"
    # ASCII names only. A tool's *listing* is display output, and on Windows
    # bsdtar transcodes non-ASCII names to the ANSI code page on the way to
    # stdout: 中文檔名.txt comes out as CP950 bytes, with or without
    # `chcp 65001`. The archive is not affected -- the same bsdtar extracts the
    # name correctly to disk, and the extraction assertions above cover that --
    # so comparing listing text for those entries measures bsdtar's display
    # convention, not interoperability. What the comparison is actually for is
    # name *shape*: trailing slashes, prefixes, path separators. Those are
    # ASCII, and this keeps testing them.
    # 僅比對 ASCII 名稱。工具的**列表**屬於顯示輸出，而 Windows 上的 bsdtar 在寫往
    # stdout 時會把非 ASCII 名稱轉為 ANSI 碼頁：中文檔名.txt 會變成 CP950 位元組，
    # 且與是否 `chcp 65001` 無關。封存本身不受影響——同一支 bsdtar 解到磁碟上的檔名
    # 是正確的，上方的解出斷言已涵蓋此點——故就這些項目比對列表文字，量到的是 bsdtar
    # 的顯示慣例而非互通性。此比對真正要檢查的是名稱的**形狀**：尾隨斜線、prefix、
    # 路徑分隔符。那些都是 ASCII，此處仍持續檢查它們。
    ascii_only() { LC_ALL=C grep -v '[^[:print:]]' "$1" | LC_ALL=C grep -v '[^ -~]' }
    if diff <(ascii_only <(sed 's#/$##' "$st_list")) <(ascii_only "$ref_list") >/dev/null 2>&1; then
        ok "$kind lists the same ASCII names as swift_tar"
    else
        bad "$kind lists the same ASCII names as swift_tar"
        diff <(ascii_only <(sed 's#/$##' "$st_list")) <(ascii_only "$ref_list") 2>&1 | head -6 | sed 's/^/        /'
    fi

    # The non-ASCII half, asserted where it is actually meaningful: extract with
    # the reference tool and check the name that lands on disk.
    # 非 ASCII 的另一半，改在真正有意義之處斷言：以參照工具解出，檢查落地的檔名。
    uni_out="$TMP/uni.$kind"
    rm -rf "$uni_out"; mkdir -p "$uni_out"
    if "$ref" -xf "$arc" -C "$uni_out" >/dev/null 2>&1 && [[ -f "$uni_out/src/中文檔名.txt" ]]; then
        ok "$kind extracts the non-ASCII name correctly"
    else
        bad "$kind extracts the non-ASCII name correctly"
    fi
done

# ---------------------------------------------------------------------
# Recorded rather than asserted: on macOS, bsdtar's AppleDouble members are a
# real difference between the tools, and someone will meet it. It is not a
# swift_tar defect -- GNU tar does the same thing swift_tar does -- so it is
# stated here instead of being hidden by COPYFILE_DISABLE and forgotten.
# 記錄而非斷言：在 macOS 上，bsdtar 的 AppleDouble 成員是工具之間的真實差異，且
# 一定會有人遇到。它不是 swift_tar 的缺陷——GNU tar 的行為與 swift_tar 相同——
# 故在此載明，而不是被 COPYFILE_DISABLE 遮蔽後遺忘。
if [[ "$PLATFORM" == mac ]]; then
    emit ""
    emit "== macOS AppleDouble note / macOS AppleDouble 說明 =="
    ad="$TMP/appledouble.tar"
    ( cd "$TMP" && /usr/bin/tar -cf "$ad" src ) >/dev/null 2>&1
    n_bsd=$(/usr/bin/tar -tf "$ad" 2>/dev/null | wc -l | tr -d ' ')
    n_st=$("$ST" -t -f "$ad" 2>/dev/null | wc -l | tr -d ' ')
    n_gnu="n/a"
    for ((i = 1; i <= ${#REF_PATH}; i++)); do
        [[ "${REF_KIND[i]}" == gnutar ]] && \
            n_gnu=$("${REF_PATH[i]}" -tf "$ad" 2>/dev/null | wc -l | tr -d ' ')
    done
    emit "  An archive written by /usr/bin/tar WITHOUT COPYFILE_DISABLE lists:"
    emit "    bsdtar    $n_bsd entries   (hides the ._ members it wrote)"
    emit "    GNU tar   $n_gnu entries   (shows them, extracts them as files)"
    emit "    swift_tar $n_st entries   (same as GNU tar)"
    emit "  swift_tar agrees with GNU tar here. Set COPYFILE_DISABLE=1 when"
    emit "  creating on macOS if the archive is for anything but bsdtar."
    emit "  swift_tar 在此與 GNU tar 一致。若封存的對象不是 bsdtar，於 macOS 建立時"
    emit "  請設定 COPYFILE_DISABLE=1。"
    if [[ "$n_st" == "$n_gnu" ]]; then
        ok "swift_tar and GNU tar agree on AppleDouble members"
    elif [[ "$n_gnu" == "n/a" ]]; then
        skipc "no GNU tar here to compare AppleDouble handling against"
    else
        bad "swift_tar and GNU tar agree on AppleDouble members"
    fi
fi

emit ""
emit "-----------------------------------------"
emit "PASS: $pass  FAIL: $fail  SKIP: $skip"

RESULTS="$HERE/tar_interop_matrix_output-$PLATFORM.txt"
if (( RECORD )); then
    if (( fail == 0 )); then
        cp "$STAGE" "$RESULTS"
        print -r -- "[Info] recorded → $RESULTS"
    else
        print -ru2 -- "[Warn] $fail failure(s); $RESULTS left unchanged / 有失敗，紀錄未更動"
    fi
else
    print -r -- "[Info] verify only; pass --record to update $(basename "$RESULTS")"
fi

(( fail == 0 ))
