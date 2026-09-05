#!/usr/bin/env zsh
# test/test_no_lzfse.zsh
# Verify the public/distributable build (compile_no_lzfse.zsh) ships NONE of the
# private LZFSE engine: no bvx3/other3 in the binary, LZFSE codecs unavailable,
# LZFSE archives undecodable — while standard codecs and plain tar still work.
# The full build (compile_tar.zsh) is used as the contrast that DOES have LZFSE.
# 驗證公開版（compile_no_lzfse.zsh）完全不含私有 LZFSE 引擎：binary 內無
# bvx3/other3、LZFSE codec 不可用、LZFSE 封存無法解碼——同時標準 codec 與純 tar
# 仍可用。以完整版（compile_tar.zsh）作為「含 LZFSE」的對照。
#
#   ./test/test_no_lzfse.zsh          build both binaries and run the checks
#                                     建置兩份執行檔並執行檢查
#   ./test/test_no_lzfse.zsh --help   print this synopsis and exit, building nothing
#                                     印出本說明後結束，不進行任何建置
set -euo pipefail

# --help is answered here, above everything. Below this point the script
# redirects stdout into a log, creates a temp dir and arms a cleanup trap, then
# runs two full builds; asking for usage used to start all of that and print
# "building full + public binaries..." instead of a synopsis.
# --help 在此、在一切之前回答。此行以下腳本會把 stdout 導入 log、建立暫存目錄並設好
# cleanup trap，接著跑兩次完整建置；先前只是想看用法，卻會啟動上述全部流程，印出的是
# 「building full + public binaries...」而不是說明。
script_path="${0:A}"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,14p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE:h}"
cd "$ROOT"

LOG="$HERE/test_no_lzfse.log"
exec > >(tee "$LOG") 2>&1
# 暫存改建在 $TMPDIR 而非 $HERE：先前建在 test/ 之下，被中斷的執行會把殘留留在版控
# 目錄裡（實際累積過 12 個）。名稱刻意不含 "lzfse" 子字串，否則會誤中本測試的 grep 檢查。
# Temp now lives in $TMPDIR rather than $HERE: it used to be created under test/,
# so an interrupted run left debris inside the versioned tree (12 had accumulated).
# The name deliberately avoids the substring "lzfse", which would false-match the
# grep checks this test performs.
# ---------------------------------------------------------------------------
# 清理與還原是兩件事，過去合在一個叫 cleanup 的函式裡。
#
# 那個函式除了 rm -rf，還會重跑一次**完整編譯**——一個名為 cleanup 的函式做了它名字沒說
# 的事，而那正是缺陷本身：兩件語意無關的責任綁在同一個名字下，其中一件瞬間且冪等，另一件
# 分鐘級且有副作用。於是「只想清掉暫存」的場合（收到訊號時）無法只做前者，因此當初只能把
# trap 限制在 EXIT，洩漏也就無解。拆開之後 trap 該掛哪些訊號不再是問題。
#
# Cleanup and restore are two different things that used to share one function named
# `cleanup`, which also re-ran a full compile. A function doing what its name does not
# say is the defect; the trap only exposed it. Split, the question of which signals to
# trap stops being a dilemma.
# ---------------------------------------------------------------------------

# 只做清理：冪等、瞬間、不需要任何外部狀態，因此掛在任何訊號上都安全。
# 用 glob 而非只刪 "$TMP"，是為了同時掃掉先前被中斷的執行所遺留的目錄——見下方為何
# 這件事不能只靠 trap。(N) 是必要的：zsh 預設 NOMATCH 在無相符時中止，而本機某處
# unsetopt nomatch 會把它藏起來，只有 `zsh -f` 或乾淨環境才看得見。
# Idempotent, instant, needs no state, so it is safe on any signal. The glob also
# sweeps debris left by earlier interrupted runs. (N) is required: zsh's default
# NOMATCH aborts when nothing matches, and a local unsetopt hides that here.
remove_temps() { rm -rf "${TMPDIR:-/tmp}"/.test_nolz.*(N) }

# 啟動時先掃一次。**這一行才是 Windows 上真正生效的部分**：實測本機 MSYS/mingw zsh 在
# 阻塞於外部指令時，跨行程送來的 INT／TERM 不會執行 trap，行程以預設處置死亡（自我送
# 訊號則會執行）。而 `timeout` 送的正是 SIGTERM。所以訊號 trap 在 macOS／Linux 上有效，
# 在此平台上不可依賴——啟動時清掃不依賴任何訊號，因此在哪裡都成立。
# Sweep on startup. This line, not the signal traps, is what works on Windows:
# measured here, an externally delivered INT/TERM does not run the trap while zsh is
# blocked in an external command; the process dies with the default disposition. And
# SIGTERM is what `timeout` sends. The startup sweep depends on no signal at all.
remove_temps

# 掃完才建立本次的 TMP。順序不能顛倒：glob 匹配所有 .test_nolz.*，若先建再掃，會把剛
# 建好的那個一併刪掉——實測確認過，而且腳本要到後面用到 TMP 時才會以「目錄不存在」的
# 形式失敗，離成因很遠。
# Create this run's TMP only after the sweep. The order matters: the glob matches every
# .test_nolz.*, so sweeping after creating would delete the directory just made —
# measured — and the script would only fail later, far from the cause.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/.test_nolz.XXXXXX")"

# 還原完整版建置：這不是清理。它必須在提前失敗時也執行（例如下方的 FATAL），否則樹上
# 留下的會是無 LZFSE 的公開版——所以它掛在 EXIT，而非只放在正常路徑的結尾。但收到訊號時
# 不執行：使用者按 Ctrl-C 要的是立刻停止，不是再等數分鐘的編譯。
# Restoring the full build is not cleanup. It must also run on an early failure (the
# FATAL below), or the tree keeps the LZFSE-less public binary — hence EXIT rather than
# the end of the happy path. It is skipped on a signal: Ctrl-C means stop now, not wait
# minutes for a compile.
# build_full 在下方依平台決定，但 trap 必須在 TMP 存在後立刻設好，故先宣告為空陣列：
# `set -u` 之下，若在分派之前就退出（例如缺 lzfse2），未宣告的陣列會讓函式自己出錯。
# build_full is chosen per platform below; declare it empty first so an exit before the
# dispatch does not make the handler itself fail under `set -u`.
build_full=()
restore_full_build() { (( ${#build_full} )) && "${build_full[@]}" >/dev/null 2>&1 || true }

interrupted=0
on_exit()   { remove_temps; (( interrupted )) || restore_full_build }
on_signal() { interrupted=1; exit 130 }
trap on_exit EXIT
trap on_signal INT TERM HUP

# The OS build, not just the product version, identifies the environment:
# macOS 27.0 build 26A5388g reported CPU Power 0 mW where 26A5406e did not.
# 辨識環境要看 OS build 而非僅產品版本：macOS 27.0 的 26A5388g 回報
# CPU Power 0 mW，26A5406e 則否。
echo "[Info] date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "[Info] os: $(command -v sw_vers >/dev/null 2>&1 && echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))" || uname -sr)"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# 本測試需要從原始碼建置兩份執行檔。曾經有一段守門在 Windows 上印出 SKIP 並以 0 結束，
# 理由是「兩支建置腳本都僅適用 POSIX」。那個理由當時為真，但守門本身留下一個更糟的形狀：
# 它只擋 Windows，於是 Linux 沒有守門也沒有可用的建置指令，測試會一路跑進 macOS 專用的
# 腳本然後失敗。守門已由下方的依平台分派取代。
#
# 那段守門原本要解決的失敗仍值得記著：未加守門時在 Windows 上執行，會印出「building
# full + public binaries...」後毫無訊息地死亡——因為兩道建置的輸出串流都被丟棄，接著
# `set -e` 在 cp 一個從未產生的執行檔時終止了腳本。現在兩道建置各自有 `|| { echo
# FATAL...; exit 1; }`，因此失敗會指名是哪一道。
#
# This test needs two builds from source. A guard used to print SKIP and exit 0
# on Windows, on the grounds that both build scripts were POSIX-only. That was
# true at the time, but the guard left a worse shape behind: it covered only
# Windows, so Linux had neither a guard nor a usable build command and ran
# straight into the macOS-only script. The guard is replaced by the per-platform
# dispatch below.
#
# The failure that guard existed to prevent is still worth recording: run
# unguarded on Windows it printed "building full + public binaries..." and then
# died with no message whatsoever, because both build streams are discarded and
# `set -e` killed the script at the `cp` of a binary that was never produced.
# Each build now carries its own `|| { echo FATAL...; exit 1; }`, so a failure
# names which one.
#
# 每個平台的「完整版」與「公開版」建置指令。
#
# 這裡原本寫死 compile_tar.zsh 與 compile_no_lzfse.zsh，而那兩支只適用 macOS
# （/opt/homebrew、otool）。後果不只是「Windows 不能跑」：Windows 有守門會 SKIP 並回傳
# 0，Linux 卻沒有，於是這支測試在 Linux 上真的去執行 compile_tar.zsh，然後以
# `Missing /opt/homebrew/lib/liblz4.dylib` 失敗——它宣稱涵蓋 Linux，實際上從未涵蓋。
#
# Linux 這一側現在可行，是因為 compile_tar-linux.zsh 已能建出含 LZFSE 的完整版；在此之
# 前它只能建排除版，本比較的「對照組」根本產不出來。公開版則以 EXCLUDE_LZFSE=1 取得，
# 那正是該腳本既有的環境覆寫。
#
# The full and public build commands for each platform.
#
# This used to hardcode compile_tar.zsh and compile_no_lzfse.zsh, which target
# macOS only (/opt/homebrew, otool). The consequence was not merely "Windows
# cannot run this": Windows had a guard that skipped and returned 0 while Linux
# had none, so on Linux the test really did run compile_tar.zsh and failed with
# `Missing /opt/homebrew/lib/liblz4.dylib` -- claiming Linux coverage it never
# had.
#
# The Linux side is possible now because compile_tar-linux.zsh can build WITH
# the LZFSE engine; before that it could only build the excluded variant, so the
# control half of this comparison could not be produced at all. The public half
# uses EXCLUDE_LZFSE=1, that script's existing environment override.
BIN=release/swift_tar
case "$(uname -s)" in
    Darwin)
        build_full=(./compile_tar.zsh)
        build_public=(./compile_no_lzfse.zsh)
        ;;
    Linux)
        # 完整版需要私有的 lzfse2 已 checkout。缺了它，compile_tar-linux.zsh 會靜默地
        # 改建排除版，於是「完整版含 bvx3」這個對照組會失敗，讀起來像產品缺陷。明說。
        # The full build needs the private lzfse2 checked out. Without it,
        # compile_tar-linux.zsh quietly builds the excluded variant instead, so
        # the "full build contains bvx3" control fails and reads as a product
        # defect. Say so instead.
        if [ ! -f lzfse2/lzfse-cli.swift ]; then
            echo "FATAL: lzfse2/lzfse-cli.swift missing; the full build has nothing to contrast against."
            echo "       Fetch it with: git submodule update --init lzfse2"
            echo "錯誤：缺少 lzfse2/lzfse-cli.swift，完整版無從作為對照。"
            echo "       請執行：git submodule update --init lzfse2"
            exit 1
        fi
        build_full=(./compile_tar-linux.zsh)
        build_public=(env EXCLUDE_LZFSE=1 ./compile_tar-linux.zsh)
        ;;
    MINGW*|MSYS*|CYGWIN*)
        BIN=release/swift_tar.exe
        build_full=(zsh ./compile_tar-win.zsh)
        build_public=(env EXCLUDE_LZFSE=1 zsh ./compile_tar-win.zsh)
        ;;
    *)
        echo "FATAL: no full/public build commands known for $(uname -s)"
        echo "錯誤：$(uname -s) 上沒有已知的完整版／公開版建置指令"
        exit 1
        ;;
esac

echo "building full + public binaries..."
# Keep stderr: a failing build used to vanish entirely because it went to
# /dev/null alongside stdout, leaving `set -e` to end the run silently.
# 保留 stderr：建置失敗原本會連同 stdout 一起進 /dev/null 而完全消失，
# 只剩 `set -e` 無聲地結束整輪。
"${build_full[@]}"   >/dev/null || { echo "FATAL: ${build_full[*]} failed";   exit 1; }
cp "$BIN" "$TMP/full"
"${build_public[@]}" >/dev/null || { echo "FATAL: ${build_public[*]} failed"; exit 1; }
cp "$BIN" "$TMP/public"
FULL="$TMP/full"; PUB="$TMP/public"

# 1) the private format name must be present in the full binary and ABSENT in
#    the public one (symbols + string literals). / bvx3 在完整版存在、公開版消失。
[ "$(strings "$FULL" | grep -c bvx3)" -gt 0 ] && ok "full build contains bvx3 (control)" \
                                              || bad "full build unexpectedly has no bvx3"
[ "$(strings "$PUB"  | grep -c bvx3)" -eq 0 ] && ok "public build has NO bvx3 in binary" \
                                              || bad "public build still contains bvx3"
[ "$(strings "$PUB"  | grep -c other3)" -eq 0 ] && ok "public build has NO other3 in binary" \
                                                || bad "public build still contains other3"

# 2) public help must not advertise any LZFSE codec / 公開版 help 不得列出 LZFSE codec
if "$PUB" --help | grep -qiE 'lzfse|bvx3|other3'; then bad "public help leaks LZFSE/bvx3/other3"
else ok "public help lists no LZFSE codec"; fi

# A compressible payload large enough to force a real bvx3 block (small inputs
# fall back to LZVN). / 夠大的可壓縮內容以觸發真正的 bvx3 區塊（小輸入會退回 LZVN）。
seq 1 500 > "$TMP/f.txt"

# 3) LZFSE encode flags are unavailable, and the public build says so instead of
#    quietly writing something else. This used to assert a silent fall back to
#    plain tar: the caller asked for --bvx3-fast, got a plain tar, and nothing
#    reported the substitution. That is the same shape as the --to-stdout defect
#    that motivated option validation -- a command doing something other than
#    what was asked, in silence. The flag names are not compiled into this build
#    at all (their absence is what check 2 above verifies with `strings`), so it
#    rejects them as unknown, which is both correct and the only outcome that
#    keeps the private engine's names out of the public binary.
# 3) LZFSE encode 旗標不可用，且公開版會明說，而非默默寫出別的東西。此處原本斷言的是
#    「靜默退回純 tar」：呼叫端要求 --bvx3-fast、拿到純 tar，卻沒有任何地方回報這個替換。
#    那與促成選項驗證的 --to-stdout 缺陷是同一種形狀——指令做了與要求不同的事，且沉默。
#    這些旗標名稱根本沒有編進本版本（上方檢查 2 正是以 `strings` 驗證其不存在），故它會
#    以「未知選項」拒絕；這既正確，也是唯一能讓私有引擎名稱不出現在公開執行檔中的結果。
if "$PUB" -c --bvx3-fast -f "$TMP/pub.bin" -C "$TMP" f.txt >/dev/null 2>&1; then
    bad "public --bvx3-fast was accepted; it should be rejected as unknown"
else
    ok "public --bvx3-fast is rejected rather than silently substituted"
fi
[ -s "$TMP/pub.bin" ] && bad "public --bvx3-fast wrote an archive despite failing" \
                      || ok "public --bvx3-fast wrote nothing"

# 4) public build cannot recover contents from an LZFSE archive made by the full
#    build. Judge by content recovery, not exit code (garbage may read as an
#    empty tar). / 公開版無法從完整版的 LZFSE 封存取回內容；以「是否取回內容」判斷
#    而非 exit code（垃圾位元可能被當成空 tar）。
"$FULL" -c --bvx3-fast -f "$TMP/lz.bvx3" -C "$TMP" f.txt
"$FULL" --identify -f "$TMP/lz.bvx3" | grep -qi 'lzfse' \
    && ok "full build made a real LZFSE archive (control)" \
    || bad "full build did not make an LZFSE archive (test setup)"
if "$PUB" -t -f "$TMP/lz.bvx3" 2>/dev/null | grep -q 'f.txt'; then
    bad "public build listed contents of an LZFSE archive"
else ok "public build cannot list an LZFSE archive"; fi
mkdir -p "$TMP/lzout"
"$PUB" -x -f "$TMP/lz.bvx3" -C "$TMP/lzout" >/dev/null 2>&1 || true
if [ -f "$TMP/lzout/f.txt" ] && cmp -s "$TMP/lzout/f.txt" "$TMP/f.txt"; then
    bad "public build extracted an LZFSE archive"
else ok "public build cannot extract an LZFSE archive"; fi
# the full build still decodes it (sanity) / 完整版仍可解（健全性）
"$FULL" -t -f "$TMP/lz.bvx3" >/dev/null 2>&1 && ok "full build decodes the LZFSE archive (control)" \
                                             || bad "full build failed to decode its own LZFSE archive"

# 5) standard codecs + plain tar still work on the public build /
#    公開版的標準 codec 與純 tar 仍正常
for spec in "plain:" "gzip:--gzip" "zstd:--zstd"; do
    name="${spec%%:*}"; flag="${spec#*:}"
    mkdir -p "$TMP/out_$name"
    # shellcheck disable=SC2086
    "$PUB" -c $flag -f "$TMP/a_$name.tar" -C "$TMP" f.txt
    "$PUB" -x -f "$TMP/a_$name.tar" -C "$TMP/out_$name"
    if cmp -s "$TMP/out_$name/f.txt" "$TMP/f.txt"; then ok "public build round-trips $name"
    else bad "public build failed $name round-trip"; fi
done

# 6) public self-test passes / 公開版自我測試通過
if "$PUB" -test >/dev/null 2>&1; then ok "public build -test passes"; else bad "public build -test failed"; fi

echo "-----------------------------------------"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
