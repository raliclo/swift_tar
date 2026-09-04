#!/usr/bin/env zsh
# =====================================================================
# bsdtar_compat.zsh -- cross-check swift_tar against standard bsdtar.
# bsdtar_compat.zsh -- 將 swift_tar 與標準 bsdtar 做交叉相容性檢查。
#
# Usage / 用法:
#   verifications/bsdtar_compat.zsh
#   FULL_CODECS=1 verifications/bsdtar_compat.zsh
#
# Exit codes / 結束碼:
#   0  OK             required checks passed / 必要檢查通過
#   10 INCOMPATIBLE  tools ran, but archive semantics differed / 語意不相容
#   20 ERROR         setup or tool invocation failed / 環境或工具錯誤
#   30 HANG          child command exceeded timeout / 子命令逾時
# =====================================================================
set -euo pipefail

readonly RC_OK=0
readonly RC_INCOMPATIBLE=10
readonly RC_ERROR=20
readonly RC_HANG=30
readonly COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-20}"

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:h}"
cd "$REPO_DIR"

case "$(uname -s)" in
    CYGWIN*|MSYS*|MINGW*) IS_WINDOWS=1 ;;
    *) IS_WINDOWS=0 ;;
esac

if (( IS_WINDOWS )); then
    BSDTAR_BIN="${BSDTAR_BIN:-C:\\Windows\\System32\\tar.exe}"
    SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-release\\swift_tar.exe}"
else
    BSDTAR_BIN="${BSDTAR_BIN:-/usr/bin/tar}"
    SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-release/swift_tar}"
fi

WORK_DIR=".tmp_bsdtar_compat.$$"
OUTPUT_TXT="$SCRIPT_DIR/bsdtar_compat_output.txt"
LOG_DIR="$SCRIPT_DIR/bsdtar_compat_logs"

CASE_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
XFAIL_COUNT=0
ERROR_COUNT=0
HANG_COUNT=0
INCOMPATIBLE_COUNT=0
HAS_TIMEOUT=0

if command -v timeout >/dev/null 2>&1; then
    set +e
    timeout --help >/dev/null 2>&1
    timeout_probe=$?
    set -e
    if (( timeout_probe == 0 )); then
        HAS_TIMEOUT=1
    fi
fi

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
exec > >(tee "$OUTPUT_TXT") 2>&1

note() { print -r -- "$*"; }

pass() {
    CASE_COUNT=$((CASE_COUNT + 1))
    note "PASS: $*"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    note "SKIP: $*"
}

xfail() {
    XFAIL_COUNT=$((XFAIL_COUNT + 1))
    note "XFAIL: $*"
}

record_status() {
    local label="$1"
    local rc="$2"
    CASE_COUNT=$((CASE_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    case "$rc" in
        "$RC_HANG")
            HANG_COUNT=$((HANG_COUNT + 1))
            note "HANG: $label"
            ;;
        "$RC_INCOMPATIBLE")
            INCOMPATIBLE_COUNT=$((INCOMPATIBLE_COUNT + 1))
            note "INCOMPATIBLE: $label"
            ;;
        "$RC_ERROR"|*)
            ERROR_COUNT=$((ERROR_COUNT + 1))
            note "ERROR: $label"
            ;;
    esac
}

cmd_path() {
    # Convert repo-relative POSIX paths to cmd.exe-friendly relative paths.
    # 將 repo-relative POSIX path 轉成 cmd.exe 可穩定解析的相對路徑。
    local p="${1//\//\\}"
    if [[ "$p" == .* && "$p" != .\\* ]]; then
        p=".\\$p"
    fi
    print -r -- "$p"
}

cmd_arg() {
    # Flags and drive-letter paths are already cmd-friendly.
    # 旗標與磁碟機絕對路徑可直接交給 cmd。
    local a="$1"
    if [[ "$a" == -* || "$a" == [A-Za-z]:\\* ]]; then
        print -r -- "$a"
    else
        cmd_path "$a"
    fi
}

run_with_optional_timeout() {
    set +e
    if (( HAS_TIMEOUT )); then
        timeout "${COMMAND_TIMEOUT_SECONDS}s" "$@"
    else
        "$@"
    fi
    local rc=$?
    set -e
    if (( rc == 0 )); then
        return "$RC_OK"
    elif (( rc == 124 || rc == 137 || rc == 143 )); then
        return "$RC_HANG"
    else
        return "$RC_ERROR"
    fi
}

run_tool() {
    local exe="$1"
    shift
    if (( IS_WINDOWS )); then
        local line
        line="$(cmd_arg "$exe")"
        local arg
        for arg in "$@"; do
            line="$line $(cmd_arg "$arg")"
        done
        run_with_optional_timeout cmd //d //c "$line" >/dev/null
    else
        COPYFILE_DISABLE=1 run_with_optional_timeout "$exe" "$@" >/dev/null
    fi
}

capture_tool() {
    local out_file="$1"
    local exe="$2"
    shift 2
    if (( IS_WINDOWS )); then
        local line
        line="$(cmd_arg "$exe")"
        local arg
        for arg in "$@"; do
            line="$line $(cmd_arg "$arg")"
        done
        run_with_optional_timeout cmd //d //c "$line" >"$out_file"
    else
        COPYFILE_DISABLE=1 run_with_optional_timeout "$exe" "$@" >"$out_file"
    fi
}

ensure_tools() {
    if ! run_tool "$SWIFT_TAR_BIN" "--version"; then
        if (( IS_WINDOWS )) && [[ -f release/swift_tar_win.zip ]]; then
            local unpack="$WORK_DIR/swift_tar_zip"
            mkdir -p "$unpack"
            unzip -q release/swift_tar_win.zip -d "$unpack"
            SWIFT_TAR_BIN="$unpack/swift_tar-win/swift_tar.exe"
            if run_tool "$SWIFT_TAR_BIN" "--version"; then
                note "INFO: using bundled swift_tar from release/swift_tar_win.zip"
            else
                note "ERROR: cannot execute swift_tar. Set SWIFT_TAR_BIN or rebuild/package first."
                exit "$RC_ERROR"
            fi
        else
            note "ERROR: cannot execute swift_tar. Set SWIFT_TAR_BIN or build first."
            exit "$RC_ERROR"
        fi
    fi

    if ! run_tool "$BSDTAR_BIN" "--version"; then
        note "ERROR: cannot execute bsdtar. Set BSDTAR_BIN explicitly."
        exit "$RC_ERROR"
    fi
    capture_tool "$LOG_DIR/bsdtar-version.txt" "$BSDTAR_BIN" "--version"
    if ! grep -qi 'bsdtar' "$LOG_DIR/bsdtar-version.txt"; then
        note "ERROR: BSDTAR_BIN does not report bsdtar:"
        sed -n '1,5p' "$LOG_DIR/bsdtar-version.txt"
        exit "$RC_ERROR"
    fi
}

make_fixture() {
    local src="$1"
    mkdir -p "$src/sub/empty-dir"
    print -r -- "root text" >"$src/root.txt"
    print -r -- "nested text" >"$src/sub/nested.txt"
    : >"$src/empty-file.txt"
    printf '\000\001\002binary\377\n' >"$src/binary.bin"
    print -r -- "long pax filename" >"$src/long-name-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz.txt"

    if [[ "${EXTENDED_ENTRIES:-0}" == "1" ]]; then
        ln "$src/root.txt" "$src/hardlink-to-root.txt" 2>/dev/null || skip "hardlink fixture could not be created"
        ln -s "root.txt" "$src/symlink-to-root.txt" 2>/dev/null || skip "symlink fixture could not be created"
    else
        skip "hardlink/symlink fixture disabled by default; rerun with EXTENDED_ENTRIES=1"
    fi
}

make_unicode_fixture() {
    local src="$1"
    mkdir -p "$src/unicode-資料夾"
    print -r -- "unicode filename" >"$src/unicode-資料夾/檔案.txt"
}

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

tree_manifest() {
    local root="$1"
    local out="$2"
    (
        cd "$root"
        find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r p; do
            if [[ -L "$p" ]]; then
                printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
            elif [[ -d "$p" ]]; then
                printf 'D %s\n' "$p"
            elif [[ -f "$p" ]]; then
                printf 'F %s %s\n' "$p" "$(hash_file "$p")"
            else
                printf '? %s\n' "$p"
            fi
        done
    ) >"$out"
}

compare_tree() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    local a="$LOG_DIR/${label}-expected.manifest"
    local b="$LOG_DIR/${label}-actual.manifest"
    tree_manifest "$expected" "$a"
    tree_manifest "$actual" "$b"
    set +e
    diff -u "$a" "$b" >"$LOG_DIR/${label}-tree.diff"
    local rc=$?
    if (( rc == 0 )); then
        set -e
        return "$RC_OK"
    fi
    return "$RC_INCOMPATIBLE"
}

check_archive_list() {
    local exe="$1"
    local archive="$2"
    local label="$3"
    local codec="${4:-}"
    local out="$LOG_DIR/${label}-list.txt"
    local args=("-t")
    if [[ -n "$codec" ]]; then args+=("$codec"); fi
    args+=("-f" "$archive")
    capture_tool "$out" "$exe" "${args[@]}" || return $?
    grep -q '^src/root.txt' "$out" || return "$RC_INCOMPATIBLE"
    grep -q '^src/sub/nested.txt' "$out" || return "$RC_INCOMPATIBLE"
}

run_roundtrip_case() {
    local name="$1"
    local swift_codec="$2"
    local bsdtar_codec="$3"
    local ext="$4"
    local fixture_root="$WORK_DIR/fixture"
    local src="$fixture_root/src"
    local swift_archive="$WORK_DIR/swift-$name.$ext"
    local bsdtar_archive="$WORK_DIR/bsdtar-$name.$ext"
    local out_bsdtar="$WORK_DIR/out-bsdtar-$name"
    local out_swift="$WORK_DIR/out-swift-$name"
    local rc

    local -a swift_args=("-c" "-f" "$swift_archive")
    if [[ -n "$swift_codec" ]]; then swift_args+=("$swift_codec"); fi
    swift_args+=("-C" "$fixture_root" "src")

    local -a bsdtar_args=("-c" "-f" "$bsdtar_archive")
    if [[ -n "$bsdtar_codec" ]]; then bsdtar_args+=("$bsdtar_codec"); fi
    bsdtar_args+=("-C" "$fixture_root" "src")

    if run_tool "$SWIFT_TAR_BIN" "${swift_args[@]}"; then
        mkdir -p "$out_bsdtar"
        local -a bsdtar_extract_args=("-x")
        if [[ -n "$bsdtar_codec" ]]; then bsdtar_extract_args+=("$bsdtar_codec"); fi
        bsdtar_extract_args+=("-f" "$swift_archive" "-C" "$out_bsdtar")
        if run_tool "$BSDTAR_BIN" "${bsdtar_extract_args[@]}"; then
            set +e
            compare_tree "$src" "$out_bsdtar/src" "$name-swift-create"
            rc=$?
            set -e
            if (( rc == RC_OK )); then pass "$name: swift_tar create -> bsdtar extract"; else record_status "$name: swift_tar create -> bsdtar extract" "$rc"; fi
        else
            record_status "$name: swift_tar create -> bsdtar extract" "$?"
        fi
    else
        record_status "$name: swift_tar create" "$?"
    fi

    if run_tool "$BSDTAR_BIN" "${bsdtar_args[@]}"; then
        mkdir -p "$out_swift"
        if run_tool "$SWIFT_TAR_BIN" "-x" "-f" "$bsdtar_archive" "-C" "$out_swift"; then
            set +e
            compare_tree "$src" "$out_swift/src" "$name-bsdtar-create"
            rc=$?
            set -e
            if (( rc == RC_OK )); then pass "$name: bsdtar create -> swift_tar extract"; else record_status "$name: bsdtar create -> swift_tar extract" "$rc"; fi
        else
            record_status "$name: bsdtar create -> swift_tar extract" "$?"
        fi
    else
        record_status "$name: bsdtar create" "$?"
    fi

    if [[ -f "$swift_archive" && -f "$bsdtar_archive" ]]; then
        local list_ok=1
        check_archive_list "$SWIFT_TAR_BIN" "$swift_archive" "$name-swift-lists-swift-archive" || { record_status "$name: swift_tar lists swift_tar archive" "$?"; list_ok=0; }
        check_archive_list "$BSDTAR_BIN" "$swift_archive" "$name-bsdtar-lists-swift-archive" "$bsdtar_codec" || { record_status "$name: bsdtar lists swift_tar archive" "$?"; list_ok=0; }
        check_archive_list "$SWIFT_TAR_BIN" "$bsdtar_archive" "$name-swift-lists-bsdtar-archive" || { record_status "$name: swift_tar lists bsdtar archive" "$?"; list_ok=0; }
        check_archive_list "$BSDTAR_BIN" "$bsdtar_archive" "$name-bsdtar-lists-bsdtar-archive" "$bsdtar_codec" || { record_status "$name: bsdtar lists bsdtar archive" "$?"; list_ok=0; }
        if (( list_ok == 1 )); then pass "$name: list smoke"; fi
    fi
}

run_unicode_case() {
    local fixture_root="$WORK_DIR/unicode-fixture"
    local src="$fixture_root/src"
    local archive="$WORK_DIR/unicode-by-swift.tar"
    local out="$WORK_DIR/out-unicode-bsdtar"
    local rc

    make_unicode_fixture "$src"
    set +e
    run_tool "$SWIFT_TAR_BIN" "-c" "-f" "$archive" "-C" "$fixture_root" "src"
    rc=$?
    set -e
    if (( rc != RC_OK )); then
        record_status "unicode path: swift_tar create" "$rc"
        return
    fi
    mkdir -p "$out"
    # No Windows XFAIL branch any more. This case failed on Windows until
    # 2026-08-18 because swift_tar emitted a short non-ASCII name as bare ustar
    # bytes with no pax "path" record, and bsdtar then decoded it through the
    # active code page. It now writes the record and the case passes, so an
    # XFAIL branch would only serve to downgrade a future regression into an
    # expected failure -- silently, on the one platform where it used to break.
    # 已不再保留 Windows 的 XFAIL 分支。本案例在 2026-08-18 之前於 Windows 失敗，
    # 原因是 swift_tar 將短的非 ASCII 名稱以裸 ustar 位元組寫出、未附 pax "path"
    # 記錄，bsdtar 遂以當前碼頁解碼。現已寫出該記錄且案例通過，故 XFAIL 分支的唯一
    # 作用會是把未來的退化降級為預期失敗——而且是在它曾經壞掉的那個平台上無聲降級。
    if run_tool "$BSDTAR_BIN" "-x" "-f" "$archive" "-C" "$out"; then
        set +e
        compare_tree "$src" "$out/src" "unicode-swift-create"
        rc=$?
        set -e
        if (( rc == RC_OK )); then
            pass "unicode path: swift_tar create -> bsdtar extract"
        else
            record_status "unicode path: swift_tar create -> bsdtar extract" "$rc"
        fi
    else
        record_status "unicode path: swift_tar create -> bsdtar extract" "$?"
    fi
}

ensure_tools

note "INFO: platform  = $(uname -s)"
note "INFO: swift_tar = $SWIFT_TAR_BIN"
note "INFO: bsdtar    = $BSDTAR_BIN"

make_fixture "$WORK_DIR/fixture/src"

run_roundtrip_case "plain" "" "" "tar"

if [[ "${FULL_CODECS:-0}" == "1" ]]; then
    run_roundtrip_case "gzip" "--gzip" "-z" "tar.gz"
    run_roundtrip_case "bzip2" "--bzip2" "-j" "tar.bz2"
    run_roundtrip_case "xz" "--xz" "-J" "tar.xz"
    run_roundtrip_case "zstd" "--zstd" "--zstd" "tar.zst"
else
    skip "compressed codec matrix disabled by default; rerun with FULL_CODECS=1"
fi

run_unicode_case

note
note "Summary: $((CASE_COUNT - FAIL_COUNT))/$CASE_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped, $XFAIL_COUNT expected-failed"
note "Failure classes: $HANG_COUNT hang, $ERROR_COUNT error, $INCOMPATIBLE_COUNT incompatible"
note "Logs: $LOG_DIR"
note "Output: $OUTPUT_TXT"

if (( HANG_COUNT != 0 )); then
    exit "$RC_HANG"
elif (( ERROR_COUNT != 0 )); then
    exit "$RC_ERROR"
elif (( INCOMPATIBLE_COUNT != 0 )); then
    exit "$RC_INCOMPATIBLE"
elif (( FAIL_COUNT != 0 )); then
    exit "$RC_ERROR"
fi
