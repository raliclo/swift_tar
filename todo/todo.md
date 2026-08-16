# swift_tar TODO / 待辦

> **Open items, 2026-08-16 / 尚未處理項目.** In rough order of consequence:
> `--keyfile=PATH` hangs an unattended run (High), `--zstd-level=N` is silently
> ignored (Medium), `lzfse2/run_round.command:50` still calls the pre-rename
> `compile_tar.sh` and is broken now, `package_win.ps1` is still PowerShell,
> `sha()` costs 892 s on Windows, and `encrypt_mbps_win_output.txt` holds
> zstd-3 numbers. Everything above was measured, not inferred; each section
> below records how.
>
> **2026-08-16 未處理項目**，依影響程度排序：`--keyfile=PATH` 會讓無人值守的執行
> 卡死（High）、`--zstd-level=N` 被靜默忽略（Medium）、
> `lzfse2/run_round.command:50` 仍呼叫改名前的 `compile_tar.sh` 而現正壞著、
> `package_win.ps1` 仍是 PowerShell、`sha()` 在 Windows 上耗時 892 秒、
> `encrypt_mbps_win_output.txt` 仍是 zstd-3 的數字。以上皆為實測而非推論，各節
> 記錄了測法。
>
> **Docs have not been tested against a reader who cannot see the code.** The
> `read_easy` skill exists for exactly that and was installed at 14:57 on
> 2026-08-16, after this session had loaded its skill list, so it could not be
> invoked here. Run it from a fresh session against this repo. A reader who only
> has the README will reach for `--keyfile=key.bin` and `--zstd-level=19`, which
> is where the two defects above surface.
> **文件尚未經「看不到程式碼的讀者」檢驗。** `read_easy` skill 正是為此而存在，但它
> 於 2026-08-16 14:57 才安裝，晚於本 session 載入 skill 清單的時間，因此在此無法
> 呼叫。請於全新 session 對本程式庫執行。只讀 README 的讀者會自然寫出
> `--keyfile=key.bin` 與 `--zstd-level=19`，而那正是上述兩個缺陷浮現之處。

Tracked issues that are known, reproduced, and deliberately not fixed yet.
`verifications/bsdtar_compat.zsh:385` already points here for its XFAIL, so this
file has to exist for that reference to mean anything.

已知、已重現、且刻意尚未修復的問題。`verifications/bsdtar_compat.zsh:385` 的 XFAIL
已指向本檔，故本檔必須存在，該引用才有意義。

## Expected failures / 預期失敗

### Unicode path: swift_tar create -> bsdtar extract (Windows only)

`bsdtar_compat.zsh` records this as XFAIL on Windows only; on macOS and Linux the
same case passes. Not yet diagnosed — the tree comparison after extraction
differs, but which side normalises the name has not been established.

`bsdtar_compat.zsh` 僅在 Windows 上將此列為 XFAIL；macOS 與 Linux 上同一案例通過。
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

### 1. encrypt_windows_correctness.zsh reports success but exits 1 / 報成功卻回傳 1  ▸ ✅ 已修正 74dd2b4

```
SUMMARY: PASS=6 FAIL=0
cleanup: tmp: parameter not set
```

`verifications/encrypt_windows_correctness.zsh:21-24` declares `local tmp` and
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

### 3. test_no_lzfse.zsh fails silently on Windows / 在 Windows 上無聲失敗  ▸ ✅ 已修正 74dd2b4

It calls `./compile_tar.zsh`, which is macOS-only (`/opt/homebrew`, `otool`), and
both streams are discarded with `>/dev/null 2>&1`. The run prints
`building full + public binaries...` and then dies with no message at all. Not
applicable here, but the failure mode should name the platform rather than
vanish.

它呼叫僅適用 macOS 的 `./compile_tar.zsh`（`/opt/homebrew`、`otool`），且以
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

## Inline `--opt=value` is accepted by validation but ignored by parsing / 內聯 `=value` 通過驗證卻被忽略

Raised in `review.md` for `--zstd-level`, then measured on 2026-08-16 with the
build from `9a4df08`. The finding holds and is wider than reported.

由 `review.md` 就 `--zstd-level` 提出，2026-08-16 以 `9a4df08` 的建置實測。該發現
成立，且範圍比原報告更廣。

**Root cause / 根因.** Option validation deliberately accepts the inline form by
checking only the name before `=`:

```swift
let name = a.hasPrefix("--") ? String(a.prefix(while: { $0 != "=" })) : a
```

but the value readers do not agree with it. `optValue()` matches the flag as a
whole argument and so never sees `--flag=value`; `optValueLong()` handles both.
**Only `--strip-components` uses `optValueLong`.** Everything else uses
`optValue`, and `--zstd-level` uses a bare `args.firstIndex(of:)`.

驗證層刻意只比對 `=` 之前的名稱，因而接受內聯形式；但讀值端並未跟上。`optValue()`
以整個引數比對旗標，故永遠看不到 `--flag=value`；`optValueLong()` 兩種都能處理。
**目前只有 `--strip-components` 使用 `optValueLong`**，其餘皆用 `optValue`，而
`--zstd-level` 更是直接用 `args.firstIndex(of:)`。

**Measured / 實測.** Corpus 14,157,900 B, `-c --zstd`:

| form / 形式 | result / 結果 | severity |
|---|---|---|
| `--strip-components=1` | works / 正常 | — |
| `--zstd-level 19` | 240,780 B | baseline |
| `--zstd-level=19` | **264,671 B — byte-identical to the default**, `rc=0` | Medium |
| `--keyfile PATH` | archive written, 14,160,537 B | baseline |
| **`--keyfile=PATH`** | **falls through to the interactive passphrase prompt and blocks; `rc=124` under a 20 s timeout, no archive produced** | **High** |
| RGB1 `--width=10` and the other 10 fields | rejected with an explicit error, `rc=1` | Low |

`--keyfile=` is the one that matters: an unattended script hangs forever rather
than failing, and produces nothing. The RGB1 fields are the acceptable shape --
they fail loudly. `--zstd-level=` is the silent one: a benchmark that sets a
level inline records numbers for a different level and exits 0.

`--keyfile=` 是關鍵：無人值守的腳本會永久卡住而非失敗，且毫無產出。RGB1 欄位屬於
可接受的形態——它們大聲失敗。`--zstd-level=` 則是靜默的那個：以內聯形式設定等級的
benchmark 會記下另一個等級的數字，並以 0 結束。

**Two candidate fixes / 兩種修法.** Either make every value reader inline-aware
(`optValue` -> `optValueLong`, and give `--zstd-level` the same helper), or have
validation reject the inline form outright. The first is friendlier; the second
is smaller and closes the gap by construction. Whichever is chosen, add a
regression case covering both spellings for at least `--keyfile` and
`--zstd-level`.
兩條路：讓所有讀值端都支援內聯，或在驗證層直接拒絕內聯形式。前者較友善，後者較小
且從構造上杜絕落差。無論採哪一種，都應為 `--keyfile` 與 `--zstd-level` 至少各補一
組涵蓋兩種寫法的回歸測試。

## Fallout from the .zsh rename / 改名後的連帶問題

### Parent repo still invokes the old name / 父 repo 仍呼叫舊檔名  ▸ ⬜ 未處理 / open

`lzfse2/run_round.command:50` runs `./swift_tar/compile_tar.sh`, which no longer
exists after `1cac313`. That line is an actual invocation in the macOS
auto-runner, not a doc reference, so the runner is broken until the parent repo
gets a matching commit. `helper_windows/run_round.bat:55` only mentions
`generate_version.sh` in a comment and is harmless.

`lzfse2/run_round.command:50` 實際執行 `./swift_tar/compile_tar.sh`，該檔在
`1cac313` 之後已不存在。那一行是 macOS 自動化執行器的真實呼叫而非文件引用，故在父
repo 補上對應提交之前，該執行器是壞的。`helper_windows/run_round.bat:55` 僅在註解
中提及舊名，無妨。

### `package_win.ps1` is still PowerShell / 仍是 PowerShell  ▸ ⬜ 未處理 / open

The user-level scripting policy reserves PowerShell for UAC elevation shims.
`compile_tar-win.bat`'s PowerShell step was replaced by `strip_runcli.zsh` in
`a753ab7`; this one is the same class and was missed. It was touched by the
rename only to update the script names it references.

使用者層級的腳本政策僅保留 PowerShell 作為 UAC 提權 shim。`compile_tar-win.bat`
的 PowerShell 步驟已於 `a753ab7` 換成 `strip_runcli.zsh`；本檔屬同一類而被遺漏。
改名只是更新了它所引用的腳本名稱。

## zsh port / zsh 移植版

### `:A` does not treat a drive-letter path as absolute / `:A` 不認磁碟機路徑為絕對路徑  ▸ ✅ 已修正(zsh port)

Re-tested 2026-08-16 after the port was patched: all three forms now resolve to
`/c/Windows`. The version string is still `5.9.999.3-test`, so do not use it to
tell the two builds apart — test the behaviour instead. Kept below because the
scripts that depend on `${0:A:h}` will meet the old build on any machine that
has not been updated.

2026-08-16 於 patch 後的移植版重測：三種形式現在都解析為 `/c/Windows`。版本字串
仍是 `5.9.999.3-test`，故不能用它區分新舊建置，要直接測行為。以下保留原始診斷，
因為依賴 `${0:A:h}` 的腳本在任何尚未更新的機器上仍會遇到舊行為。

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
(`verifications/bsdtar_compat.zsh:24`, `verifications/tgz_inflight_rss_win.zsh:29`,
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
