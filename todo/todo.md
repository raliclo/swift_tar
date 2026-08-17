# swift_tar TODO / 待辦

> **Open items, 2026-08-18 / 尚未處理項目.** In rough order of consequence:
> `--encrypt` under `< /dev/null` hangs forever on Windows (High),
> `--keyfile=PATH` hangs an unattended run (High), `--zstd-level=N` is silently
> ignored (Medium), `lzfse2/run_round.command:50` still calls the pre-rename
> `compile_tar.sh` and is broken now, `package_win.ps1` is still PowerShell,
> `sha()` costs 892 s on Windows, `encrypt_mbps_win_output.txt` holds
> zstd-3 numbers, and a trailing `/` on an input path doubles every separator in
> the archive, which silently breaks `--delete` and makes `-u` double the archive
> (Medium-High). Everything above was measured, not inferred; each section below
> records how.
>
> **2026-08-18 未處理項目**，依影響程度排序：`--encrypt` 在 `< /dev/null` 下於
> Windows 永久卡死（High）、`--keyfile=PATH` 會讓無人值守的執行
> 卡死（High）、`--zstd-level=N` 被靜默忽略（Medium）、
> `lzfse2/run_round.command:50` 仍呼叫改名前的 `compile_tar.sh` 而現正壞著、
> `package_win.ps1` 仍是 PowerShell、`sha()` 在 Windows 上耗時 892 秒、
> `encrypt_mbps_win_output.txt` 仍是 zstd-3 的數字、輸入路徑帶尾隨 `/` 會使封存中
> 所有分隔符加倍，進而無聲破壞 `--delete` 並使 `-u` 讓封存翻倍（Medium-High）。
> 以上皆為實測而非推論，各節記錄了測法。
>
> **The `read_easy` blind test has been started but is nowhere near finished:
> 1 round of a planned 100.** See the section below for what round 1 found. The
> run stopped on a model usage limit, not on a result, so the remaining 99 rounds
> are still owed. A reader who only has the README will reach for
> `--keyfile=key.bin` and `--zstd-level=19`, which is where the two defects above
> surface — and neither has been exercised by the blind test yet.
> **`read_easy` 盲測已啟動但遠未完成：計畫 100 回合，目前 1 回合。** round 1 的發現
> 見下節。中止原因是模型額度上限而非測試結果，故其餘 99 回合仍待補。只讀 README 的
> 讀者會自然寫出 `--keyfile=key.bin` 與 `--zstd-level=19`，而那正是上述兩個缺陷浮現
> 之處——且盲測尚未觸及這兩者。

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

## read_easy blind test / read_easy 盲測

A `general-purpose` agent restricted to `README.md` and `README.zh-TW.md` — no
source, no scripts, no git history, and specifically **no `--help`** — running one
task per round against `release/swift_tar.exe` (build 20260816-150106). Findings
below are the ones I re-measured myself; the agent's own classification is
recorded where it differed from mine, because that difference is the useful part.

一個受限於 `README.md` 與 `README.zh-TW.md` 的 `general-purpose` agent——不得讀原始碼、
腳本、git 歷史，尤其不得用 `--help`——對 `release/swift_tar.exe`（建置
20260816-150106）每回合做一項測試。以下是我親自重測過的發現；agent 的分類若與我不同
則一併記錄，因為有價值的正是那個落差。

### Round 1: a trailing slash on the input path doubles every separator / 輸入路徑的尾隨斜線使所有分隔符加倍  ▸ ⬜ 未處理 / open

The agent reported this round CLEAN. It was not — the defect was sitting in the
output it pasted, and it read only its own exit code. Measured on 2026-08-16:

agent 將本回合報為 CLEAN。並非如此——缺陷就在它自己貼出的輸出裡，而它只看了離開碼。
2026-08-16 實測：

```
swift_tar -c -f a.tar tree/   ->  -t prints  tree//a.txt     diverges
swift_tar -c -f b.tar tree    ->  -t prints  tree/a.txt      matches bsdtar
bsdtar    -cf c.tar tree/     ->  -t prints  tree/a.txt
```

`archiveName()` at `swift_tar.swift:2093` normalises backslashes, the drive
letter, and leading `/` and `./`, but not a **trailing** `/`. The walker at
`swift_tar.swift:2132` then recurses with `path + "/" + child` on the argument as
given, so the doubled separator propagates to every entry underneath, where it is
no longer trailing but interior — which is why stripping the trailing slash alone
is not sufficient; the repeated `/` has to be collapsed.

`swift_tar.swift:2093` 的 `archiveName()` 會正規化反斜線、磁碟機代號、開頭的 `/` 與
`./`，卻不處理**尾隨**的 `/`。`swift_tar.swift:2132` 的走訪器接著以原引數做
`path + "/" + child` 遞迴，於是加倍的分隔符擴散到底下每一個項目，且此時它已不在結尾
而在中間——這正是「只去尾隨斜線」不夠的原因，重複的 `/` 必須摺疊。

**Severity: initially assessed Low. Raised to Medium-High by round 8 — see
below.** Extraction really is unaffected: swift_tar and bsdtar both restore the
doubled-slash archive correctly, and `--strip-components=1` still works. The
first assessment stopped there, and that was the mistake: it checked the paths
that *read data* and never checked the paths that *match names*.

**嚴重度：初判 Low，經 round 8 上修為 Medium-High——見下。** 解壓確實不受影響：
swift_tar 與 bsdtar 都能正確還原，`--strip-components=1` 亦正常。初判止步於此，而這
正是失誤所在：它檢查了**讀取資料**的路徑，卻沒檢查**比對名稱**的路徑。

Not a README defect — the README's description of `-c` is accurate. Deliberately
not fixed in the same pass as the doc work, because it needs a rebuild to verify.
非 README 缺陷——README 對 `-c` 的描述正確。刻意不與文件工作同批修正，因為驗證需要重建。

### Round 8: the doubled separator breaks every name-matching operation / 加倍的分隔符使所有依名稱比對的操作失效  ▸ ⬜ 未處理 / open

Round 1 called the doubled separator cosmetic because extraction survives it.
Round 8 shows that conclusion was drawn from too narrow a sample. Measured
2026-08-18 on an archive created from `tree/`:

round 1 因解壓不受影響而判定加倍分隔符僅屬外觀問題。round 8 顯示該結論取樣過窄。
2026-08-18 以 `tree/` 建立的封存實測：

```
--delete -f slash.tar tree/a.txt     ->  'tree/a.txt': not found in archive, rc=1
--delete -f slash.tar 'tree//a.txt'  ->  rc=0, deleted
```

The file is unambiguously in the archive. The name the user would type — the name
it actually has on disk — does not match, and the only spelling that works is the
doubled one copied out of `-t` output. `--delete` is documented as "matching
entry by name", and it does; the stored name is simply not the name anyone would
write.

該檔確實在封存中。使用者會鍵入的名稱——也就是它在磁碟上的真實名稱——比對不到，唯一
有效的寫法是從 `-t` 輸出複製出來的加倍版本。README 說 `--delete` 依名稱比對，它確實
如此；問題在於存進去的名稱不是任何人會寫的那個。

**`-u` is worse, because it fails silently.** Create with `tree/`, then update
with `tree` without modifying a single file:

**`-u` 更糟，因為它無聲失敗。** 以 `tree/` 建立，再以 `tree` 更新，且未修改任何檔案：

```
created with "tree/"          ->   8 entries
-u with "tree", nothing edited -> 16 entries, 16 distinct names, rc=0
-u with "tree/" (consistent)   ->  11 entries (the 3 dirs, which -u always re-adds)
```

`-u` means "append only members that are newer or absent". Every member was
present, under a spelling that did not match, so all were judged absent and the
archive doubled — exit 0, no warning. Repeated updates grow it without bound.
Extraction still yields the right tree because the later copy wins, which is
exactly why nobody would notice.

`-u` 的語意是「只追加較新或不存在的成員」。所有成員都在，只是拼法不符，於是全被判為
不存在而使封存翻倍——離開碼 0，毫無警告。反覆更新會讓它無限膨脹。解出的樹仍然正確，
因為後寫入的那份勝出——這正是沒有人會察覺的原因。

**Fix the root cause, not the call sites.** Collapsing repeated `/` and stripping
a trailing `/` in `archiveName()` closes `--delete`, `-u`, the `-t` divergence and
anything added later that matches on names. Patching the matchers individually
would leave the next name-based feature to rediscover this.

**應修根因而非各呼叫點。** 在 `archiveName()` 中摺疊重複的 `/` 並去除尾隨 `/`，即可
一併解決 `--delete`、`-u`、`-t` 輸出差異，以及日後任何依名稱比對的新功能。逐一修補
比對端，只會讓下一個依名稱比對的功能重新踩到同一個坑。

### Round 4: `--encrypt` hangs forever on `< /dev/null` (Windows) / `--encrypt` 在 `< /dev/null` 下永久卡死（Windows）  ▸ ⬜ 未處理 / open

The README promises that swift_tar "refuses to write an archive it cannot key
rather than silently leaving it unencrypted" when stdin is not a terminal. The
guard exists and works — but only for pipes. Measured 2026-08-18:

README 承諾 stdin 非終端機時 swift_tar「寧可拒絕，也不默默寫出未加密的封存」。該守門
確實存在且有效——但只對管線有效。2026-08-18 實測：

```
printf '' | swift_tar -c --encrypt -f b.enc tree   ->  documented error, rc=1, no file
printf 'pw\npw\n' | swift_tar -c --encrypt ...     ->  documented error, rc=1, no file
swift_tar -c --encrypt -f a.enc tree < /dev/null   ->  prompt printed, HANGS FOREVER
                                                       (rc=124 only because timeout killed it)
```

**Two independent causes, both at the Windows branch / 兩個各自獨立的成因，都在 Windows 分支：**

1. `crypto.swift:847` tests `_isatty(_fileno(stdin))`. On Windows `_isatty` is true
   for **any character device**, and `< /dev/null` under MSYS becomes the Windows
   `NUL` device, which is one. A pipe is not, which is exactly why the pipe cases
   are caught and this one is not. The correct test is `GetConsoleMode()` on the
   stdin handle, which fails for `NUL`.
2. `crypto.swift:879` then reads with `_getch()` (conio), which reads the
   **physical console and ignores stdin redirection entirely**. So nothing can
   ever satisfy it: it is not waiting on the redirected stdin, it is waiting on a
   keyboard. That is the infinite part.

1. `crypto.swift:847` 以 `_isatty(_fileno(stdin))` 判斷。Windows 的 `_isatty` 對
   **任何字元裝置**皆為真，而 `< /dev/null` 在 MSYS 下即 Windows 的 `NUL` 裝置，正
   屬字元裝置；管線則否——這正是管線擋得住、本例擋不住的原因。正確判法是對 stdin
   handle 呼叫 `GetConsoleMode()`，其對 `NUL` 會失敗。
2. `crypto.swift:879` 接著以 `_getch()`（conio）讀取，該函式讀的是**實體主控台，完全
   無視 stdin 重導向**。故沒有任何輸入能滿足它：它等的不是那個被重導的 stdin，而是鍵盤。
   這才是「永久」的來源。

**Severity: High for unattended use.** `< /dev/null` is the canonical way to run
a command non-interactively — it is what cron and many service managers hand a
job as stdin. The failure shape is the worst kind: no error, no archive, no exit,
just a job that never finishes.

**嚴重度：無人值守情境下為 High。** `< /dev/null` 正是把命令跑成非互動的標準寫法——
cron 與許多 service manager 給任務的 stdin 就是它。其失敗形態屬最惡劣的一類：沒有錯誤、
沒有產出、也不結束，只是一個永遠跑不完的工作。

Related but distinct from the `--keyfile=PATH` inline-option hang recorded above:
that one never reaches the guard because the value is never parsed; this one
reaches the guard and the guard wrongly says "terminal".

與上文 `--keyfile=PATH` 的內聯選項卡死相關但不同：那一個是值根本沒被解析，故從未走到
守門；本項則走到了守門，而守門誤判為「終端機」。

### Round 6: `--zstd-level` is the only path that exits 2 / 只有 `--zstd-level` 會回傳 2  ▸ ⬜ 未處理 / open

Found while establishing the exit-status contract for the README. Measured
2026-08-18 across twelve failure modes: every one exits 1 — missing archive,
corrupt archive, unknown option, missing input path, no mode given, no files
given, negative `--strip-components` — **except** `--zstd-level`, which exits 2.

為 README 建立離開碼契約時發現。2026-08-18 對十二種失敗情形實測：封存檔不存在、封存
損毀、未知選項、輸入路徑不存在、未指定模式、未指定檔案、`--strip-components` 為負，
全部回傳 1——**唯獨** `--zstd-level` 回傳 2。

`swift_tar.swift:3729` and `:3734` are the only two `exit(2)` calls in the file;
the other sixteen error paths all use `exit(1)`. So the 2 is a one-off in that
block rather than a category, and nothing documents it as meaning anything.

`swift_tar.swift:3729` 與 `:3734` 是全檔僅有的兩處 `exit(2)`，其餘十六處錯誤路徑皆為
`exit(1)`。故此 2 是該區塊的孤例而非一種分類，且無任何文件賦予它意義。

Either make it 1 like everything else, or give 2 a documented meaning and apply
it consistently. The README now sidesteps the question by telling readers to test
zero versus non-zero and not to branch on a specific value — which is honest and
stays true either way, but it is a workaround for an inconsistency, not a fix.

要嘛改為與其他路徑一致的 1，要嘛賦予 2 明確意義並一致套用。README 目前以「請判斷零或
非零、不要針對特定值分支」迴避此問題——這是誠實的寫法且無論如何都不會過期，但那是對
不一致的迴避，不是修正。

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
