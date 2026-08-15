# platform.zsh -- the one place that decides what this platform is called.
# platform.zsh -- 決定本平台名稱的唯一來源。
#
# Sourced, not executed. The suffix it returns names version-<plat>.txt and the
# per-platform measurement outputs under verifications/. Those files record
# facts that differ per platform — which libraries a binary linked, how fast it
# ran — so a build or a test run on one platform must never land on another
# platform's file.
# 本檔供 source 而非執行。它回傳的後綴用於命名 version-<平台>.txt 與 verifications/
# 之下的各平台量測輸出。那些檔案記錄的是逐平台不同的事實——執行檔連結了哪些函式庫、
# 跑得多快——故某平台的建置或測試絕不可寫進另一平台的檔案。
#
# Kept as a sourced function rather than copied into each caller: the copies had
# already started to drift in wording, and a detection that disagrees between
# the builder and the test runner is worse than no detection at all.
# 以 source 的函式形式集中，而非複製到各呼叫端：先前的複本在寫法上已開始分歧，而
# 「建置端與測試端偵測結果不一致」比完全沒有偵測更糟。

swift_tar_platform() {
    case "$(uname -s)" in
        Darwin)               echo mac ;;
        Linux)                echo linux ;;
        MINGW*|MSYS*|CYGWIN*) echo win ;;
        # Anything else gets its own lowercased name rather than being forced
        # into one of the three: a wrong suffix silently overwrites a real
        # platform's record, an unfamiliar one merely looks unfamiliar.
        # 其他系統取其小寫名稱，而非硬塞進上述三者之一：錯誤的後綴會靜默覆蓋某個
        # 真實平台的紀錄，而陌生的後綴頂多只是看起來陌生。
        *)                    uname -s | tr '[:upper:]' '[:lower:]' ;;
    esac
}
