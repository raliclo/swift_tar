# cmake_configure.zsh -- a CMake configure step that a kill halfway cannot poison
# cmake_configure.zsh -- 中途被砍也不會留下壞掉建置目錄的 CMake 設定步驟
#
#   . ./cmake_configure.zsh
#   cmake_configure <build dir> -S <source dir> <cmake arguments...>
#
# A configure that is killed partway (out of memory, Ctrl-C, a closed terminal) leaves a half-
# written CMakeCache.txt and config.h, and the next build reuses them: on Multissh-W11 the reused
# libarchive tree failed with "'long long type-name' is invalid" and "SIZE_MAX macro redefined"
# until the directory was deleted by hand (2026-11-20). A marker file is written before cmake
# runs and removed only when it succeeds, so a marker found at the start means the last configure
# did not finish, and that directory is removed and configured again. A directory without the
# marker -- including every one from before this file existed -- is reused as before. Same scheme
# as multissh's helper/build_swift_tar.zsh, which reported this.
# 中途被砍的設定（記憶體不足、Ctrl-C、關掉終端機）會留下寫了一半的 CMakeCache.txt 與 config.h，
# 而下次建置會沿用它們：Multissh-W11 上沿用的 libarchive 建置樹以「'long long type-name' is
# invalid」與「SIZE_MAX macro redefined」失敗，直到手動刪掉目錄（2026-11-20）。cmake 執行前先寫一個
# 標記檔，成功後才刪掉；開始時若看到標記，就表示上次的設定沒有完成，那個目錄會被移除並重新設定。
# 沒有標記的目錄——包括這個檔案出現之前的每一個——照舊沿用。與回報此事的 multissh
# helper/build_swift_tar.zsh 同一套做法。
#
# A configure that fails on its own also keeps the marker, so the next run starts from an empty
# directory rather than from whatever that failure left.
# 自行失敗的設定也會留下標記，所以下次從空目錄開始，而不是從那次失敗留下的東西開始。

# The lock sits outside the directory recovery removes. A killed shell may leave it behind;
# confirm its cmake children stopped before removing it. / 鎖放在復原所刪目錄之外；shell 遭砍後
# 可能留下鎖，移除前須確認其 cmake 子程序已停止。
cmake_configure() (
    local dir=$1; shift
    local mark="$dir/.swift_tar-configuring"
    local lock="${dir%/}.swift_tar-configure.lock" owner
    mkdir -p -- "${lock:h}" || return
    if ! mkdir -- "$lock"; then
        owner=""
        [[ ! -r $lock/pid ]] || owner=$(<"$lock/pid")
        if [[ $owner == <-> ]] && ! kill -0 "$owner" 2>/dev/null; then
            print -ru2 -- "Stale configure lock $lock; confirm cmake has stopped before removing it / 設定鎖已殘留，移除前請確認 cmake 已停止"
        else
            print -ru2 -- "Configure lock busy: $lock (owner ${owner:-starting}) / 設定鎖正在使用中"
        fi
        return 1
    fi
    trap 'rm -f -- "$lock/pid"; rmdir -- "$lock"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    print -r -- "$$" > "$lock/pid" || return
    if [[ -e $mark ]]; then
        print -r -- "[Info] $dir: an earlier CMake configure did not finish; removing it / 上次的 CMake 設定沒有完成，移除重建"
        rm -rf -- "$dir"
    fi
    mkdir -p -- "$dir"
    : > "$mark"
    cmake -B "$dir" "$@" || return
    rm -f -- "$mark"
)
