# swift_tar TODO / 待辦

Tracked issues that are known, reproduced, and deliberately not fixed yet.
`verifications/bsdtar_compat.sh:385` already points here for its XFAIL, so this
file has to exist for that reference to mean anything.

已知、已重現、且刻意尚未修復的問題。`verifications/bsdtar_compat.sh:385` 的 XFAIL
已指向本檔，故本檔必須存在，該引用才有意義。

## Expected failures / 預期失敗

### Unicode path: swift_tar create -> bsdtar extract (Windows only)

`bsdtar_compat.sh` records this as XFAIL on Windows only; on macOS and Linux the
same case passes. Not yet diagnosed — the tree comparison after extraction
differs, but which side normalises the name has not been established.

`bsdtar_compat.sh` 僅在 Windows 上將此列為 XFAIL；macOS 與 Linux 上同一案例通過。
尚未診斷——解出後的樹比對不一致，但究竟是哪一端對檔名做了正規化仍未確認。

## Windows verification run, 2026-08-16 / Windows 驗證執行

Twelve verification scripts run on Windows against the build from `a753ab7`.
Result: 8 clean, 2 with real findings, 3 not applicable on this platform.
`swift_tar.exe -test` passed with no failures, and `compile_tar-win.bat`
succeeded twice in a row.

以 `a753ab7` 的建置在 Windows 上執行 12 支驗證腳本。結果：8 支乾淨、2 支有實質發現、
3 支在本平台不適用。`swift_tar.exe -test` 全數通過，`compile_tar-win.bat` 連續兩次成功。

Status as of 2026-08-16: items 1, 2 and 3 were fixed in `74dd2b4` and are kept
below with the fix recorded, because the reasoning is what makes the fix
checkable. Item 4 is still open — `sha()` at
`parallel_extract_correctness.zsh:123` remains two process spawns per file.

2026-08-16 狀態：項目 1、2、3 已於 `74dd2b4` 修正，仍保留於下並記錄修法，因為可供
查核的是其推理而非結論。項目 4 尚未處理——`parallel_extract_correctness.zsh:123`
的 `sha()` 仍是每檔兩個行程。

### 1. encrypt_windows_correctness.sh reports success but exits 1 / 報成功卻回傳 1  ▸ ✅ 已修正 74dd2b4

```
SUMMARY: PASS=6 FAIL=0
cleanup: tmp: parameter not set
```

`verifications/encrypt_windows_correctness.sh:21-24` declares `local tmp` and
defines `cleanup() { rm -rf "$tmp"; }` **inside** a function, then arms
`trap cleanup EXIT`. The trap fires after that function has returned, when the
`local` is out of scope, so `set -u` aborts the cleanup and the script exits 1.

This is the dangerous shape: the summary says success and the exit code says
failure, so any gate keying on the exit code sees a failure that the output
denies. Fix by hoisting `tmp` to a global.

`:21-24` 在函式**內部**宣告 `local tmp` 並定義 `cleanup()`，再掛上
`trap cleanup EXIT`。該 trap 在函式返回之後才觸發，此時 `local` 已離開作用域，
`set -u` 於是中止 cleanup，腳本回傳 1。這是最危險的形態：摘要說成功、離開碼說失敗，
任何以離開碼判定的閘門都會得到與輸出相反的結論。修法是把 `tmp` 提為全域。

### 2. parallel_extract_correctness.zsh: mode checks lack a Windows guard / mode 檢查缺 Windows 守門  ▸ ✅ 已修正 74dd2b4

```
./a.txt          -> 644 (want 755)   FAIL
./sub/b.txt      -> 644 (want 600)   FAIL
./sub/deep/c.txt -> 644 (want 644)   PASS
```

NTFS has no POSIX mode bits and MSYS reports 644 for every regular file — which
is why the case that *wants* 644 is the one that passes. This is a platform
limitation, **not a swift_tar regression**: the same script passes its other ten
checks, including the parallel-extract ordering cases it exists to protect.

The script already skips its unwritable-destination case on platforms where the
precondition cannot be met; the mode checks need the same treatment rather than
failing.

NTFS 沒有 POSIX mode bits，MSYS 對所有一般檔案皆回報 644——這正是「想要 644」的那個
案例反而通過的原因。此為平台限制，**並非 swift_tar 退化**：同一支腳本其餘十項檢查
（含它真正要保護的平行解壓順序案例）全部通過。該腳本對「不可寫目的地」已有前提不成立
即跳過的機制，mode 檢查應比照處理，而非直接失敗。

### 3. test_no_lzfse.sh fails silently on Windows / 在 Windows 上無聲失敗  ▸ ✅ 已修正 74dd2b4

It calls `./compile_tar.sh`, which is macOS-only (`/opt/homebrew`, `otool`), and
both streams are discarded with `>/dev/null 2>&1`. The run prints
`building full + public binaries...` and then dies with no message at all. Not
applicable here, but the failure mode should name the platform rather than
vanish.

它呼叫僅適用 macOS 的 `./compile_tar.sh`（`/opt/homebrew`、`otool`），且以
`>/dev/null 2>&1` 丟棄兩個輸出串流。執行後只印出 `building full + public binaries...`
便毫無訊息地結束。本平台雖不適用，但失敗時應指明平台，而不是靜默消失。

### 4. parallel_extract_correctness.zsh takes 892 s on Windows / 在 Windows 上耗時 892 秒  ▸ ⬜ 未處理 / open

`verifications/parallel_extract_correctness.zsh:123` hashes with
`sha() { shasum -a 256 "$1" | cut -d' ' -f1 }` — two process spawns per file.
Over 405 files across several `-n` arms that is tens of thousands of spawns, and
process creation on Windows costs far more than on POSIX. Hashing the whole file
list in one `sha256sum` invocation would remove nearly all of it.

`:123` 的 `sha()` 每個檔案要 spawn 兩個行程；405 個檔案乘以多個 `-n` 組別即上萬次
spawn，而 Windows 的行程建立成本遠高於 POSIX。改以單次 `sha256sum` 處理整份清單即可
去掉絕大部分成本。

### 5. encrypt_mbps_win_output.txt still holds zstd-3 numbers / 仍是 zstd-3 的數字  ▸ ⬜ 未處理 / open

`c24c139` pinned `--zstd-level 9` in the measurement scripts and re-measured
every affected record. The macOS record `encrypt_mbps_rss_output.txt` was
re-run then (dated 2026-08-15); its Windows counterpart was not, and still
carries the 2026-08-06 run from `c788aeb`, taken when the default was 3.

So `encrypt_mbps_win.sh:231` now asks for level 9 while the committed table next
to it reports level 3, and nothing in the file says which. Only the Windows
machine can close this — re-run the script there and commit the result.

`c24c139` 在量測腳本中釘住 `--zstd-level 9` 並重測所有受影響的紀錄。macOS 的
`encrypt_mbps_rss_output.txt` 當時已重跑（日期 2026-08-15）；Windows 對應檔未重跑，
仍是 `c788aeb` 於 2026-08-06、預設等級為 3 時的執行結果。

於是 `encrypt_mbps_win.sh:231` 要求等級 9，而緊鄰的入版表格回報的是等級 3 的結果，
且檔內未載明何者。此項只有 Windows 機器能結——在該機重跑腳本並提交結果即可。

### Not applicable on Windows, failing cleanly / 本平台不適用，且失敗訊息清楚

- `verifications/rgb1/mixed_size_delta.zsh` — needs `swift_tar_DOE` built first.
  需先建置 `swift_tar_DOE`。
- `verifications/rgb1/test_interframe.zsh` — needs the source clip under
  `/Volumes/Windows/...`. 需要 `/Volumes/Windows/...` 下的來源影片。

## zsh port / zsh 移植版

### `:A` does not treat a drive-letter path as absolute / `:A` 不認磁碟機路徑為絕對路徑

Reproduced 2026-08-15 on the Windows zsh port (5.9.999.3-test):

```
cd /tmp
${:-C:/Windows}:A   ->  /tmp/C:/Windows     wrong
${:-C:\Windows}:A   ->  /tmp/C:\Windows     wrong
${:-/c/Windows}:A   ->  /c/Windows          correct
${:-/tmp}:A         ->  /tmp                correct
```

`cd` accepts all three forms, so the shell disagrees with itself about what
counts as absolute. This matters because `${0:A:h}` is the standard idiom for
"directory of this script" and at least six scripts here use it
(`verifications/bsdtar_compat.sh:24`, `verifications/tgz_inflight_rss_win.sh:29`,
`verifications/rgb1/mixed_size_delta.zsh:22`,
`verifications/rgb1/nv12_vs_rgb1_streaming.zsh:35`, and others). Invoked with a
relative path it is fine; invoked with a `C:/...` absolute path it silently
yields cwd + the drive path, and the script writes its output somewhere nobody
looks.

於 Windows zsh 移植版（5.9.999.3-test）重現如上。`cd` 三種形式全部接受，故該 shell
對「何謂絕對路徑」自相矛盾。其重要性在於 `${0:A:h}` 是取「本腳本所在目錄」的標準
寫法，本程式庫至少六支腳本在用。以相對路徑呼叫無事；以 `C:/...` 絕對路徑呼叫則會
靜默得到 cwd 加上磁碟路徑，腳本便把輸出寫到無人查看之處。

Fix belongs in the zsh port, not here. Reported to its maintainer.
修復屬於 zsh 移植版而非本程式庫，已回報給維護者。
