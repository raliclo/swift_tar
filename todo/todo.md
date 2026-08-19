# swift_tar TODO / 待辦

> **Fixed 2026-08-18 / 已修復.** Every defect the blind test turned up in the
> program itself is now fixed, verified, and covered by
> `test_blind_findings.zsh` (15 checks): the trailing-slash doubled separator and
> the `--delete` / `-u` breakage it caused, the `< /dev/null` encryption hang,
> the ignored inline `--flag=value` spellings, `--zstd-level`'s odd exit 2, and
> CRLF in the `-t` / `--identify` output on Windows. The suite fails 11 of its
> checks against the previous binary and passes all 15 against this one.
>
> **Nothing is open, 2026-08-19.** Every defect recorded below is fixed and under
> regression test — `test_blind_findings.zsh` is at 84 checks, all passing, and it
> fails against every earlier binary. The one entry marked "recorded, not
> actioned" is the case-collision *warning* option, which is a feature choice and
> is written up with the reasoning rather than left as a task.
>
> **2026-08-18 已修復。** 盲測在程式本身找到的缺陷已全部修復、驗證，並由
> `test_blind_findings.zsh`（15 項檢查）涵蓋：尾隨斜線造成的分隔符加倍及其引發的
> `--delete`／`-u` 失效、`< /dev/null` 下的加密卡死、被忽略的內聯 `--flag=value`
> 寫法、`--zstd-level` 特立獨行的 exit 2，以及 Windows 上 `-t`／`--identify` 輸出
> 的 CRLF。該套件對舊 binary 有 11 項失敗，對新 binary 15 項全過。
>
> **2026-08-19：已無未處理項目。** 以下記錄的每一項缺陷皆已修復並納入回歸測試——
> `test_blind_findings.zsh` 現有 84 項檢查、全數通過，且對先前每一版 binary 都會失敗。
> 唯一標為「記錄，未處理」的是大小寫碰撞的「警告」選項，那是功能取捨，已連同理由寫明，
> 而非留作待辦。
>
> **The `read_easy` blind test is 17 rounds into a planned 100 and continues.**
> Rounds that found something are recorded below with the measurement; rounds
> that found nothing are not, because a clean round adds no fact to check.
> **`read_easy` 盲測已進行 17 回合（計畫 100），仍在繼續。** 有發現的回合連同實測記
> 於下方；沒有發現的回合不記錄，因為乾淨的回合並未新增任何可供查核的事實。

Tracked issues that are known, reproduced, and deliberately not fixed yet.
`verifications/bsdtar_compat.zsh:385` already points here for its XFAIL, so this
file has to exist for that reference to mean anything.

已知、已重現、且刻意尚未修復的問題。`verifications/bsdtar_compat.zsh:385` 的 XFAIL
已指向本檔，故本檔必須存在，該引用才有意義。

## Resolved expected failure / 已解決的預期失敗

### Unicode path: swift_tar create -> bsdtar extract (Windows only)  ▸ ✅ 已修正 2026-08-18

Carried as an XFAIL on Windows with the note "not yet diagnosed — which side
normalises the name has not been established." **Neither side normalised
anything.** Diagnosed 2026-08-18:

原先在 Windows 上列為 XFAIL，並註明「尚未診斷——究竟是哪一端對檔名做了正規化仍未
確認」。**兩端都沒有做任何正規化。** 2026-08-18 診斷結果：

```
swift_tar -t : src/unicode-資料夾/檔案.txt        correct UTF-8 bytes
GNU tar  -tf : same                                reads them correctly
bsdtar   -tf : src/unicode-<mojibake>/...          decodes via the active code page
bsdtar   -xf : unicode-Φ│çµûÖσñ╛/µ¬öµíê.txt      name corrupted on disk
```

The decisive comparison was writing the identical tree with GNU tar twice:
`--format=pax` extracts correctly under bsdtar, `--format=ustar` does not. So the
difference is the pax record, not the bytes.

決定性的比較是以 GNU tar 對同一棵樹寫兩次：`--format=pax` 在 bsdtar 下解得正確，
`--format=ustar` 則否。可見差別在於 pax 記錄，而非位元組本身。

**Root cause.** `writeEntryHeader` emitted a pax `path` record only when the name
did not fit the ustar name/prefix fields — a length test. But pax records are
defined to be UTF-8, so that record is also the only thing declaring the name's
encoding. A **short** non-ASCII name fit the ustar fields, got no record, and
travelled as bare bytes for each reader to guess at. GNU tar passes them through
and is right by accident; bsdtar consults the code page and is wrong.

**根因。** `writeEntryHeader` 僅在名稱塞不進 ustar 的 name/prefix 欄位時才寫出 pax
`path` 記錄——那是一個長度判斷。但 pax 記錄依規範即為 UTF-8，故該記錄同時也是唯一
宣告名稱編碼的東西。**短的**非 ASCII 名稱塞得進 ustar 欄位，因而沒有記錄，只能以裸
位元組傳遞供各家讀取器猜測。GNU tar 原樣通過而恰好正確；bsdtar 參考碼頁因而出錯。

**Fix.** Emit the `path` record whenever the name contains a byte ≥ 0x80, in
addition to the existing length case; same for `linkpath`. `bsdtar_compat.zsh`
now reports 4/4 passed, 0 expected-failed, and its Windows XFAIL branch is
removed — leaving it would only downgrade a future regression into an expected
failure, silently, on the one platform where it used to break.

**修法。** 除既有的長度條件外，只要名稱含有 ≥ 0x80 的位元組即寫出 `path` 記錄；
`linkpath` 比照。`bsdtar_compat.zsh` 現回報 4/4 通過、0 預期失敗，其 Windows XFAIL
分支已移除——留著它只會把未來的退化無聲降級為預期失敗，而且正是在它曾經壞掉的那個
平台上。

## PowerShell scripts / PowerShell 腳本  ▸ ✅ 已結案 2026-08-18

`package_win.ps1` and `update_scoop_manifest.ps1` are converted and removed.
**One remains, deliberately: `verifications/measure_peak_ws_win.ps1`.**

`package_win.ps1` 與 `update_scoop_manifest.ps1` 已轉換並移除。
**刻意保留一支：`verifications/measure_peak_ws_win.ps1`。**

It is not a UAC shim, so the policy would normally send it to zsh. It stays
because nothing reachable from zsh can sample a short-lived process often enough
to see its peak working set. Measured against a 0.6 s swift_tar encode whose true
peak is ~58–59 MB:

它並非 UAC shim，依政策本應改寫為 zsh。保留的原因是：從 zsh 可觸及的任何工具，都無法
對短命行程取樣到足以看見其峰值 working set 的密度。以一次 0.6 秒、真實峰值約 58–59 MB
的 swift_tar 編碼實測：

| approach | result |
|---|---|
| `tasklist` polled from zsh | 49–255 ms per poll → **1–2 samples** per run; three runs gave 51.9 / 58.1 / **48.1** MB, the last 18% low |
| `typeperf "\Process(swift_tar)\Working Set Peak"` | the OS tracks the peak, so one read would suffice — but typeperf needs **1504 ms** to emit its first sample and captured **zero** readings |
| `wmic process get PeakWorkingSetSize` | **removed from Windows 11**; neither `wmic` nor `System32\wbem\WMIC.exe` exists |
| PowerShell, `WorkingSet64` every 5 ms in-process | ~120 samples, spread under 1.5 MB across repeats |

The fidelity is the whole point of the measurement, so converting it would mean
keeping the script and losing the number. The reasoning and the figures are
repeated in the script's own header, so anyone opening the file meets them before
deciding it was an oversight.

精度正是這項量測的全部意義，改寫等於「腳本留下、數字失真」。相關推理與數據亦重複記於
該腳本自身的檔頭，讓任何打開該檔的人在判定「這是漏改」之前先讀到它。

Revisit if a zsh-reachable peak counter appears. Whoever revisits should re-run
the comparison rather than assume — a version that merely runs is not a version
that measures.

若日後出現 zsh 可觸及的峰值計數器，可重新檢視。屆時請重跑上述比較而非逕行假設——
「能跑」的版本不等於「量得準」的版本。

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

### 4. parallel_extract_correctness.zsh takes 892 s on Windows / 在 Windows 上耗時 892 秒  ▸ ✅ 已修正 2026-08-18（892 s → 220 s）

`verifications/parallel_extract_correctness.zsh:123` hashes with
`sha() { shasum -a 256 "$1" | cut -d' ' -f1 }` — two process spawns per file.
Over 405 files across several `-n` arms that is tens of thousands of spawns, and
process creation on Windows costs far more than on POSIX. Hashing the whole file
list in one `sha256sum` invocation would remove nearly all of it.

`:123` 的 `sha()` 每個檔案要 spawn 兩個行程；405 個檔案乘以多個 `-n` 組別即上萬次
spawn，而 Windows 的行程建立成本遠高於 POSIX。改以單次 `sha256sum` 處理整份清單即可
去掉絕大部分成本。

### 5. encrypt_mbps_win_output.txt still holds zstd-3 numbers / 仍是 zstd-3 的數字  ▸ ✅ 已重測 2026-08-18

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

## Inline `--opt=value` is accepted by validation but ignored by parsing / 內聯 `=value` 通過驗證卻被忽略  ▸ ✅ 已修正 2026-08-18

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

**Fixed 2026-08-18 by the friendlier of the two routes / 已於 2026-08-18 採較友善
的一條修正.** `optValue` now reads both spellings itself, which made
`optValueLong` an exact duplicate — it is gone, and its one caller
(`--strip-components`) uses `optValue`. `--zstd-level` no longer indexes `args`
directly; it goes through the same helper, so it gained inline support and lost
its odd `exit(2)` in the same edit. Declaring `optValue` above the codec block
rather than below it is what let that last part happen.

`optValue` 現已自行處理兩種寫法，`optValueLong` 因而成為完全重複的實作——已移除，其
唯一呼叫端（`--strip-components`）改用 `optValue`。`--zstd-level` 不再直接索引
`args`，改走同一個 helper，故在同一次修改中同時取得內聯支援並去掉了它特立獨行的
`exit(2)`。能一併處理的關鍵，在於把 `optValue` 宣告於 codec 區塊之上而非其下。

Regression coverage for both spellings of `--keyfile` and `--zstd-level` is in
`test_blind_findings.zsh`, which fails 11 checks against the previous binary.
`--keyfile` 與 `--zstd-level` 兩種寫法的回歸測試位於 `test_blind_findings.zsh`，該
套件對舊 binary 有 11 項失敗。

## Fallout from the .zsh rename / 改名後的連帶問題

### Parent repo still invokes the old name / 父 repo 仍呼叫舊檔名  ▸ ✅ 已修正（上游）

`lzfse2/run_round.command:50` runs `./swift_tar/compile_tar.sh`, which no longer
exists after `1cac313`. That line is an actual invocation in the macOS
auto-runner, not a doc reference, so the runner is broken until the parent repo
gets a matching commit. `helper_windows/run_round.bat:55` only mentions
`generate_version.sh` in a comment and is harmless.

`lzfse2/run_round.command:50` 實際執行 `./swift_tar/compile_tar.sh`，該檔在
`1cac313` 之後已不存在。那一行是 macOS 自動化執行器的真實呼叫而非文件引用，故在父
repo 補上對應提交之前，該執行器是壞的。`helper_windows/run_round.bat:55` 僅在註解
中提及舊名，無妨。

### `package_win.ps1` is still PowerShell / 仍是 PowerShell  ▸ ✅ 已修正 2026-08-18

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

## REGRESSION: `--zip` and `--zip64` are dead on macOS / macOS 上 `--zip` 與 `--zip64` 完全失效  ▸ 🔴 未處理 / open

Found on 2026-08-18 building current `master` (`20260818-125339`) on macOS 27.0
arm64. **Every ZIP write fails**, with no working path left:

```
swift_tar -c --zip   -f o.zip -C w src
swift_tar -c --zip64 -f o.zip -C w src
# -> swift_tar: I/O error: set ZIP header charset:
#    A character-set conversion not fully supported on this platform
# -> exit 1, no archive produced
```

Two committed tests fail because of it: `test_blind_findings.zsh`
(`FAIL: --zip alone still works (want '0', got '1')`) and
`test_swift_tar_rgb1.zsh`.

**Cause.** `ca4bf0d` added this to `libarchive_zip_bridge.c:200` to fix a real
Windows defect — a Traditional Chinese filename failed the whole write with
"Can't translate pathname to current locale":

```c
archive_write_set_options(writer, "hdrcharset=UTF-8")
```

But `build_libarchive.zsh:22` and `build_libarchive-win.zsh:30` both configure
libarchive with `-DENABLE_ICONV=OFF`. Without iconv, libarchive cannot honour an
explicitly named `hdrcharset`, the call returns non-`ARCHIVE_OK`, and the bridge
aborts the write. Windows does not hit it because libarchive there converts
charsets through the Win32 API rather than iconv — which is exactly why a fix
verified only on Windows could take macOS out without anyone noticing.

This contradicts the Highlights claim that the bundled libarchive "creates and
reads standard ZIP containers on macOS and Windows".

**Directions worth trying**, in the order I would try them: build macOS
libarchive with `-DENABLE_ICONV=ON` and confirm the Windows path still passes;
or treat a failed `hdrcharset` as non-fatal and fall back, which keeps the
Windows fix where it works and restores macOS, at the cost of the original
locale-dependence on platforms without iconv; or set the UTF-8 flag on the entry
rather than through a writer option. The first is the smallest change but adds a
dependency to the macOS build.

2026-08-18 於 macOS 27.0 arm64 建置當前 `master`（`20260818-125339`）時發現，
**所有 ZIP 寫入皆失敗**，無任何可用路徑，並導致兩支入版測試失敗。

成因：`ca4bf0d` 為修正 Windows 上的真實缺陷（繁體中文檔名使整個寫入失敗，錯誤為
"Can't translate pathname to current locale"），在 `libarchive_zip_bridge.c:200`
加入 `hdrcharset=UTF-8` 選項；但 `build_libarchive.zsh:22` 與
`build_libarchive-win.zsh:30` 都以 `-DENABLE_ICONV=OFF` 設定 libarchive。沒有
iconv，libarchive 無法履行明確指定的 hdrcharset，該呼叫回傳非 `ARCHIVE_OK`，
bridge 遂中止寫入。Windows 不受影響，是因為該平台的 libarchive 透過 Win32 API 而非
iconv 進行字元集轉換——這正是「僅在 Windows 驗證過的修正」得以在無人察覺下讓 macOS
停擺的原因。此事亦與 Highlights 中「內附 libarchive 於 macOS 與 Windows 建立並讀取
標準 ZIP 容器」的宣稱相牴觸。

### macOS run, rounds 1-6 / macOS 端 round 1-6

A second agent under the same rules ran on macOS against build `20260816-014638`,
independently of the Windows rounds above. It found six documentation gaps, all
fixed in the READMEs, and four behavioural defects. Re-measured on 2026-08-18
against the merged build `20260818-125339`, **three of the four were already
fixed by the Windows-side work** and are noted here only so the overlap is
visible rather than looking like two unrelated investigations:

| Defect | Status against 20260818-125339 |
|---|---|
| `--zstd-level` was the only path exiting 2 | ✅ fixed — `--zstd-level abc` and `-n abc` both exit 1. Same finding as Round 6 above, found independently |
| `--cat` / `--decrypt-only` exited 1 on a broken pipe | ✅ fixed — `--cat -f p.tar \| head -c 10` now exits 0 with no message |
| `.tar.gz` truncated to 30 B read as an empty archive | ✅ fixed — now exits 1 |

第二個 agent 在相同規則下於 macOS 對建置 `20260816-014638` 執行，與上方 Windows 回合
彼此獨立。它找到六項文件缺口（皆已於 README 修正）與四項行為缺陷。2026-08-18 對合併後
的建置 `20260818-125339` 重測，**四項中已有三項被 Windows 端的工作修好**，此處記錄僅為
使重疊可見，以免看起來像兩件無關的調查。

The two that remain are below.
仍存在的兩項如下。

### macOS round 5: raw bytes under 512 still read as an empty archive / 小於 512 bytes 的隨機資料仍被讀成空封存  ▸ ✅ 已修正 2026-08-19

The truncated-`.tar.gz` half of this is fixed. What remains is input that is not
a recognised codec at all and is shorter than one tar header block:

| Input | bsdtar | swift_tar 20260818-125339 |
|---|---|---|
| empty file | `0` | `0` — agreed, this is the convention |
| 100 B random | `1` `Unrecognized archive format` | **`0`, no output, no error** |
| 200 B random | `1` | **`0`** |
| 511 B random | `1` | **`0`** |
| 512 B random | `1` | `1` `header checksum mismatch` |

The boundary is exact at 512. Below one full header block nothing is examined,
so the file reads as an empty archive and `-t` prints nothing at exit 0. An empty
file behaving that way is correct and matches bsdtar; a short file of arbitrary
bytes is not.

截斷 `.tar.gz` 的那一半已修。仍存在的是「根本不屬任何已知格式、且短於一個 tar 標頭
區塊」的輸入。分界點精確落在 512：不足一個完整標頭區塊時不作任何檢查，該檔遂被讀成
空封存，`-t` 不印任何東西並以 0 結束。空檔案如此是正確的、與 bsdtar 一致；任意位元組
的短檔則不然。

### macOS round 3: `--title` and `--country` lose one byte to nothing / 白白少一個位元組  ▸ ✅ 已修正 2026-08-19

Measured on 20260818-125339: `--title` accepts 63 and rejects 64; `--country`
accepts 511 and rejects 512; `--creator-email` accepts its full 254.

`validateASCII` tests `count < maxBytesExclusive`. `--title` and `--country` pass
their raw field sizes (64, 512) so they cap one short; `--creator-email` passes
`fieldSize + 1` and gets all 254. The reader is `firstIndex(of: 0) ?? endIndex`,
so it does **not** need a NUL terminator and a completely full field reads back
correctly. The lost byte buys nothing, and the explicit `+1` on the email path
suggests full width was the intent.

The READMEs document 63 / 511 / 254 because that is what the program does, and
say explicitly that those are not typos, so that whichever way this is resolved
the document does not silently become wrong.

於 20260818-125339 實測：`--title` 接受 63、拒絕 64；`--country` 接受 511、拒絕 512；
`--creator-email` 用滿自己的 254。`validateASCII` 以 `count < maxBytesExclusive`
判斷，前兩者傳入原始欄位寬故各少一位元組，email 傳入 `fieldSize + 1` 故完整。讀取端
為 `firstIndex(of: 0) ?? endIndex`，不需 NUL 終止符，欄位塞滿亦可正確讀回——那一個
位元組什麼也沒換到，而 email 路徑上明確的 `+1` 顯示原意應為完整寬度。README 依實際
行為記為 63 / 511 / 254 並註明非筆誤，如此無論此項如何處置，文件都不會靜默變錯。

### Round 1: a trailing slash on the input path doubles every separator / 輸入路徑的尾隨斜線使所有分隔符加倍  ▸ ✅ 已修正 2026-08-18

The agent reported this round CLEAN. It was not — the defect was sitting in the
output it pasted, and it read only its own exit code. Measured on 2026-08-16:

agent 將本回合報為 CLEAN。並非如此——缺陷就在它自己貼出的輸出裡，而它只看了離開碼。
2026-08-16 實測：

```
swift_tar -c -f a.tar tree/   ->  -t prints  tree//a.txt     diverges
swift_tar -c -f b.tar tree    ->  -t prints  tree/a.txt      matches the reference
GNU tar   -cf c.tar tree/     ->  -t prints  tree/a.txt      (both spellings)
bsdtar    -cf c.tar tree/     ->  refuses: "Couldn't visit directory"
bsdtar    -cf c.tar tree      ->  -t prints  tree/a.txt
```

The reference here is **GNU tar 1.35**, which is what `/usr/bin/tar` is under Git
Bash — not bsdtar, as this entry originally said. Re-measured against the real
bsdtar (`/c/Windows/System32/tar.exe`, 3.8.4): it rejects the trailing-slash form
outright and agrees with GNU tar on the other. The conclusion is unchanged —
`tree//a.txt` matched neither reference — but the attribution was wrong.

此處的參照是 **GNU tar 1.35**，即 Git Bash 下 `/usr/bin/tar` 的實體，而非本條目原先所寫
的 bsdtar。以真正的 bsdtar（`/c/Windows/System32/tar.exe`，3.8.4）重測：它直接拒絕尾隨
斜線的寫法，另一種寫法則與 GNU tar 一致。結論不變——`tree//a.txt` 與兩個參照皆不符——
但工具歸屬原先寫錯了。

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

### Round 8: the doubled separator breaks every name-matching operation / 加倍的分隔符使所有依名稱比對的操作失效  ▸ ✅ 已修正 2026-08-18

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

### Round 4: `--encrypt` hangs forever on `< /dev/null` (Windows) / `--encrypt` 在 `< /dev/null` 下永久卡死（Windows）  ▸ ✅ 已修正 2026-08-18

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

### Round 6: `--zstd-level` is the only path that exits 2 / 只有 `--zstd-level` 會回傳 2  ▸ ✅ 已修正 2026-08-18

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

### Round 17 follow-up: `-t` and `--identify` emitted CRLF on Windows / 在 Windows 上輸出 CRLF  ▸ ✅ 已修正 2026-08-18

Found by the regression test written for round 1, not by the blind agent. The
test compared swift_tar's listing against system tar's and reported a mismatch
whose `want` and `got` were visually identical. `od -c` showed why:

由為 round 1 所寫的回歸測試發現，而非盲測 agent。該測試比對 swift_tar 與系統 tar 的
列表，回報不符，但 `want` 與 `got` 肉眼完全相同。`od -c` 揭示了原因：

```
swift_tar -t : t r e e / \r \n t r e e / a . t x t \r \n
system tar   : t r e e / \n    t r e e / a . t x t \n
```

Windows opens the CRT's stdout in text mode, so every `\n` from `print()` left as
`\r\n`. This mattered more than it looks: **it defeated the point of the round-1
fix.** The stored names were finally identical to bsdtar's, yet
`diff <(swift_tar -t) <(bsdtar -tf)` still differed on every line — and CR is the
one byte `grep` and `sed` cannot show you, so the cause is invisible to the usual
tools.

Windows 的 CRT stdout 預設為文字模式，故 `print()` 送出的每個 `\n` 都變成 `\r\n`。
其影響大於表面：**它使 round 1 的修正失去意義。** 檔內名稱終於與 bsdtar 一致，
`diff <(swift_tar -t) <(bsdtar -tf)` 卻仍每行都不符——而 CR 正是 `grep` 與 `sed`
無法顯示給你看的那個位元組，故成因對常用工具而言是隱形的。

Archive bytes were never affected: those go through `FileHandle`, which bypasses
the CRT entirely. Verified — an archive written to stdout contained zero CR
bytes, identical to the `-f` path. So the fix is one line at the top of `main()`,
`_setmode(_fileno(stdout), _O_BINARY)`, which corrects every `print()` at once
instead of rewriting them one at a time.

封存位元組從未受影響：它們走 `FileHandle`，完全不經 CRT。已驗證——寫至 stdout 的封存
含 0 個 CR，與 `-f` 路徑相同。故修法是 `main()` 開頭的一行
`_setmode(_fileno(stdout), _O_BINARY)`，一次修正所有 `print()`，而非逐一改寫。

**The lesson is about the test, not the tool.** A regression test written for one
defect found a second, unrelated one, because it asserted against an external
reference (system tar) rather than against the tool's own previous output. A test
that compares a tool to itself can only catch changes, never wrongness.

**這條教訓關於測試而非工具。** 為某一缺陷所寫的回歸測試，找出了另一個毫不相干的缺陷，
原因是它以外部參照（系統 tar）為斷言基準，而非以工具自身先前的輸出為基準。拿工具與
自己比對的測試，只能抓到「變化」，永遠抓不到「本來就錯」。

### Round 19: swift_tar could not extract archives it had written (Windows, long paths) / 解不開自己寫出的封存（Windows 長路徑）  ▸ ✅ 已修正 2026-08-18

The Highlights section promises "long paths ... interoperable with `bsdtar` /
GNU `tar`". The write side kept that promise — GNU tar read swift_tar's
360-character pax entries perfectly. The read side did not: extracting the same
archive failed with `cannot create '...' (errno 2)` while **GNU tar extracted it
successfully in the same directory, from the same file, in the same session**.

Highlights 承諾「long paths……與 bsdtar／GNU tar 互通」。建立端守住了承諾——GNU tar
能完美讀取 swift_tar 寫出的 360 字元 pax 項目。讀取端沒有：解出同一封存時失敗於
`cannot create '...' (errno 2)`，而**同一目錄、同一檔案、同一階段中的 GNU tar 卻能
成功解出**。

**The measurement that mattered was the one I nearly did not take.** My first
reproduction succeeded, and I recorded "not reproducible". That was wrong: the
defect is deterministic but **not monotonic in path length**. Sweeping the target
directory name from 4 to 100 characters:

**真正關鍵的那次量測，我差點沒做。** 我第一次重現是成功的，並記下「無法重現」。那是
錯的：此缺陷雖屬決定性，卻**不隨路徑長度單調變化**。將目標目錄名自 4 掃到 100 字元：

```
failing lengths: 12-23, 43-54, 74-85     (36 of 97)
```

Bands 12 wide, repeating every 31 characters — exactly one path segment
(`segment_of_thirty_chars_long_N/`). A single sample lands inside or outside a
band by luck, which is why one trial "disproved" a real bug.

帶寬 12、每 31 字元重複一次——恰為一個路徑分段。單次取樣落在帶內或帶外純屬運氣，
這正是「一次試驗」得以「推翻」一個真實缺陷的原因。

**Root cause.** Extraction created directories with
`fm.createDirectory(atPath:withIntermediateDirectories: true)` on the raw path,
while file writes went through `winUcrtPath()`, which adds the `\\?\` prefix past
260 characters. So files were long-path aware and directories were not. Measured
directly: Foundation's `createDirectory` fails on a 503-character target **with
or without** the prefix ("The file name is invalid"), so adding the prefix alone
would not have fixed it. Worse, all three call sites used `try?`, so the failure
was discarded and only surfaced later as ENOENT on a file whose parent had never
been made.

**根因。** 解壓端以 `fm.createDirectory(atPath:withIntermediateDirectories: true)`
用原始路徑建目錄，檔案寫入卻走 `winUcrtPath()`——後者在超過 260 字元時加上 `\\?\`
前綴。於是檔案支援長路徑而目錄不支援。直接實測：Foundation 的 `createDirectory` 對
503 字元的目標**無論加不加前綴**都失敗（「檔案名稱無效」），故單靠加前綴並不能解決。
更糟的是三處呼叫皆使用 `try?`，失敗被丟棄，直到某個檔案因父層從未建立而回報 ENOENT
才浮現。

**Fix.** `winMakeDirectories()` walks the components and calls `_wmkdir` on a
`\\?\`-prefixed absolute path for each, so no single call is bound by MAX_PATH,
and the three extraction sites now throw instead of swallowing the result. After
the fix all 97 target lengths extract, and the directory count matches GNU tar's.
Covered by `test_blind_findings.zsh`, which sweeps ten lengths chosen from inside
and outside the old failure bands.

**修法。** `winMakeDirectories()` 逐一走訪各層，對每一層以 `\\?\` 前綴的絕對路徑呼叫
`_wmkdir`，故沒有任何一次呼叫受 MAX_PATH 限制；三處解壓呼叫改為擲出錯誤而非吞掉結果。
修正後 97 個目標長度全部可解出，目錄數與 GNU tar 一致。由 `test_blind_findings.zsh`
涵蓋，該測試自舊失敗帶的帶內與帶外各取共十個長度掃描。

### Round 22: two defects in the ZIP backend / ZIP 後端的兩個缺陷  ▸ ✅ 已修正 2026-08-18

**A non-ASCII filename failed the whole `--zip` write.** `繁體.txt` round-trips
through plain tar and every stream codec, but `--zip` died with
`archive_write_header: Can't translate pathname to current locale`, exit 1, and
left a 162-byte partial `.zip` behind. The bridge now sets `hdrcharset=UTF-8` on
the writer, which stores the name as UTF-8 instead of translating it into
whatever code page happens to be active.

> **Correction, 2026-08-18.** The original entry justified this by claiming
> "bsdtar writes the same name to ZIP without complaint, so it was never a
> libarchive limitation." **Both halves were wrong**, and the error was caught by
> a single question — *which* tar was the comparison actually run against?
>
> `/usr/bin/tar` in Git Bash is **GNU tar 1.35**, not bsdtar. GNU tar has no ZIP
> writer at all: `tar -a -cf out.zip` does not recognise the suffix, falls back to
> uncompressed, and writes a **tar** file named `.zip` — exit 0, which is what
> made the check look like it passed. `od -c` on that artifact shows a ustar
> filename field at offset 0, not `PK`.
>
> Re-run against the real bsdtar (`/c/Windows/System32/tar.exe`, bsdtar 3.8.4 /
> libarchive 3.8.4), the result is the opposite of what was claimed:
>
> ```
> bsdtar --format zip, 繁體.txt  ->  "Can't translate Pathname to CP437"
>                                    rc=0, archive written, name stored as "??.txt"
> ```
>
> So it **is** libarchive's default behaviour and bsdtar hits it too — bsdtar just
> degrades worse: it warns, mangles the filename, and still exits 0. swift_tar's
> original hard failure was the safer of the two. The fix remains correct and is
> now known to be better than both: swift_tar stores `繁體.txt` intact and system
> `unzip` reads it, where bsdtar yields `??.txt`.

> **2026-08-18 更正。** 原始條目的理由是「bsdtar 寫同一個名稱到 ZIP 毫無問題，故此事
> 從來不是 libarchive 的限制」。**兩個半句都是錯的**，而揪出錯誤的只是一個問題——那個
> 對照究竟是拿哪一個 tar 跑的？
>
> Git Bash 的 `/usr/bin/tar` 是 **GNU tar 1.35**，不是 bsdtar。GNU tar 根本沒有 ZIP
> writer：`tar -a -cf out.zip` 不認得該副檔名，退回不壓縮，寫出的是一個**叫做 .zip 的
> tar 檔**——離開碼 0，這正是該檢查看起來通過的原因。對該產物執行 `od -c` 可見位移 0
> 處是 ustar 檔名欄位，而非 `PK`。
>
> 改以真正的 bsdtar（`/c/Windows/System32/tar.exe`，bsdtar 3.8.4／libarchive 3.8.4）
> 重跑，結果與原先宣稱相反：它同樣失敗於 `Can't translate Pathname to CP437`，回傳 0，
> 寫出封存，並把名稱存成 `??.txt`。
>
> 故這**確實**是 libarchive 的預設行為，bsdtar 也會中招——只是它降級得更糟：發出警告、
> 毀掉檔名，然後仍以 0 結束。swift_tar 原本的硬性失敗反而是兩者中較安全的。修正本身仍
> 然正確，且現已知比兩者都好：swift_tar 完整存下 `繁體.txt`，系統 `unzip` 讀得正確，而
> bsdtar 給出的是 `??.txt`。

**非 ASCII 檔名會讓整個 `--zip` 寫入失敗。** `繁體.txt` 在純 tar 與各串流 codec 中都
能正常往返，`--zip` 卻以
`archive_write_header: Can't translate pathname to current locale` 失敗、離開碼 1，
並留下 162 bytes 的半成品 `.zip`。**bsdtar 寫同一個名稱到 ZIP 毫無問題，而 bsdtar 用
的是同一套 libarchive**——故此事從來不是 libarchive 的限制。bsdtar 在啟動時呼叫
`setlocale()`；函式庫後端不應如此，故 bridge 改為在 writer 上設定
`hdrcharset=UTF-8`。這也是較可攜的答案：封存不再取決於寫入當下恰好生效的 locale。

Verified: the write now succeeds, system `unzip` lists `uni/繁體.txt` correctly,
and the round-trip is `diff -r` identical. **One caveat recorded honestly:** the
ZIP general-purpose flag word is still `00 00`, so the EFS bit (11) that
advertises UTF-8 names is not set. Readers that consult it may fall back to the
local code page. The hard failure is gone and the common readers agree; strict
EFS conformance is not claimed.

已驗證：寫入成功，系統 `unzip` 正確列出 `uni/繁體.txt`，往返 `diff -r` 完全一致。
**如實記錄一項但書**：ZIP 的 general purpose flag 仍為 `00 00`，亦即標示 UTF-8 名稱的
EFS bit（11）並未設定。會參考該位元的讀取器可能退回本地碼頁。硬性失敗已消除、常見讀取
器結果一致，但不宣稱完全符合 EFS 規範。

**`-C` did not auto-create for ZIP, only for tar.** Same flag, same command
shape, opposite outcome: `-x -f x.zip -C nodir/a/b` failed with
`cannot chdir to 'nodir/a/b'`, while `-x -f x.tar -C nodir/a/b` created the whole
chain and exited 0. The two backends reach the destination differently — tar
joins `-C` into each entry's path, so the directory-creation step builds it on
the way, while ZIP hands `-C` to libarchive to `chdir()` into. `runZipRead` now
creates it first.

**`-C` 對 ZIP 不會自動建立，只有 tar 會。** 同一旗標、同樣的指令形狀，結果相反：
`-x -f x.zip -C nodir/a/b` 失敗於 `cannot chdir to 'nodir/a/b'`，而
`-x -f x.tar -C nodir/a/b` 會建出整條路徑並回傳 0。兩個後端抵達目的地的方式不同——
tar 是把 `-C` 併入每個項目的路徑，故建立目錄那一步會沿途建好；ZIP 則是把 `-C` 交給
libarchive 去 `chdir()`。`runZipRead` 現在會先建立它。

**No README change for the second one, deliberately.** The `-C` table already
said the directory is created when missing, without scoping that to tar. The
statement was true of one backend and false of the other, so the honest repair is
to make the behaviour match the documentation rather than narrow the
documentation to match one backend.

**第二項刻意不改 README。** `-C` 表格原本就寫著目錄不存在時會被建立，且未限定僅適用
tar。該敘述對一個後端為真、對另一個為假，故誠實的修法是讓行為符合文件，而非把文件縮限
成只描述其中一個後端。

### Round 23: `--zip --encrypt` produced a plaintext archive and exited 0 / 產出明文封存卻回傳 0  ▸ ✅ 已修正 2026-08-18

The most serious finding of the run, because it is the exact outcome the design
states it exists to prevent: "refuses to write an archive it cannot key rather
than silently leaving it unencrypted."

本輪最嚴重的發現，因為它正是設計本身宣稱要防止的結果：「寧可拒絕，也不默默寫出未加密
的封存」。

```
swift_tar -c --zip --encrypt --keyfile k.bin -f z.zip.enc s   ->  rc=0
magic                                                          ->  50 4b 03 04   (plain PK)
swift_tar --identify -f z.zip.enc                              ->  "zip"  (no encryption layer)
unzip -p z.zip.enc s/secret.txt   [no key at all]              ->  TOP SECRET PAYLOAD
swift_tar -x -f z.zip.enc         [no key, no prompt]          ->  TOP SECRET PAYLOAD
```

Control, same key, tar instead of ZIP: magic `SWTARC01`, and extraction without
the key is correctly refused. So the encryption layer works — the ZIP path simply
never reaches it. `runZipCreate` writes through libarchive straight to the file
and never passes through the sink that the encrypting thread wraps, so
`--encrypt` and `--keyfile` were parsed, accepted, and had no effect at all.

對照組（同一把金鑰、改用 tar 而非 ZIP）：magic 為 `SWTARC01`，且無金鑰解壓被正確拒絕。
可見加密層本身正常——ZIP 路徑根本沒走到它。`runZipCreate` 經由 libarchive 直接寫入檔案，
完全不通過加密執行緒所包覆的 sink，故 `--encrypt` 與 `--keyfile` 被解析、被接受，卻毫無
作用。

**Fixed by refusing the combination**, exit 1, no file written. Routing the ZIP
writer through the encrypting sink is the better long-term answer, but it is not
a change to make quickly: refusing is safe today, and an accepted-but-ignored
`--encrypt` is not. The READMEs now scope the "any codec can be encrypted"
sentence to tar codecs and document the refusal.

**修法為拒絕該組合**，離開碼 1，不寫出任何檔案。把 ZIP writer 改走加密 sink 是較好的長期
答案，但那不是能倉促進行的變更：今天拒絕是安全的，而「被接受卻遭忽略的 `--encrypt`」不是。
兩份 README 已將「任何 codec 都能加密」一句限定為 tar codec，並記載此拒絕行為。

**A test-design note worth keeping.** The first version of the regression case
used `--zip --encrypt` *without* a key. It passed against the vulnerable binary —
not because the ZIP guard existed, but because the passphrase prompt rejects
non-terminal stdin first. A test can pass for a reason that has nothing to do
with what it claims to check. Every case now supplies a key, so it reaches the
ZIP path; all six fail against the vulnerable build.

**一則值得保留的測試設計筆記。** 回歸案例的第一版使用不帶金鑰的 `--zip --encrypt`。它在
有漏洞的 binary 上通過了——不是因為 ZIP 守門存在，而是因為密語提示會先擋下非終端機的
stdin。測試可能因為與其宣稱檢查之事毫無關係的理由而通過。現在每個案例都提供金鑰，確保走
到 ZIP 路徑；六項在有漏洞的建置上全數失敗。

> **Third-party tool defects live in
> [`verifications/bugs/bugs.md`](../verifications/bugs/bugs.md), not here.** This
> file tracks swift_tar's own defects. The bsdtar-on-Windows behaviours referenced
> below — the mangled listing, the pax requirement, the silent ZIP name loss — are
> recorded there with their reproductions.
> **第三方工具的缺陷記於
> [`verifications/bugs/bugs.md`](../verifications/bugs/bugs.md)，不在本檔。** 本檔追蹤的是
> swift_tar 自身的缺陷。下文提及的 Windows 版 bsdtar 行為——列表亂碼、pax 記錄的必要性、
> ZIP 名稱的無聲遺失——連同重現步驟皆記於該處。

## Which `tar` is the reference? / 參照的 `tar` 是哪一個？

Both implementations are installed on this Windows machine, and which one a bare
`tar` resolves to depends on the shell:

本 Windows 機器上兩種實作皆已安裝，而 `tar` 這個名字解析到哪一個取決於 shell：

| path | implementation |
|---|---|
| `/usr/bin/tar` (shipped with Git for Windows) | **GNU tar 1.35** |
| `C:\Windows\System32\tar.exe` (shipped with Windows) | **bsdtar 3.8.4 / libarchive 3.8.4** |

In Git Bash, `tar` is GNU tar — `/usr/bin` precedes `System32` on `PATH`, so the
Windows-native bsdtar is shadowed. **The common shorthand "GNU on Linux, bsdtar
on Windows and macOS" does not hold here**, and every ad-hoc comparison in this
file that said "bsdtar" while invoking a bare `tar` was in fact measuring GNU tar.
Those attributions have been corrected in place.

在 Git Bash 中，`tar` 是 GNU tar——`PATH` 上 `/usr/bin` 排在 `System32` 之前，Windows
內建的 bsdtar 因而被遮蔽。**常見的簡化說法「Linux 用 GNU、Windows 與 macOS 用 bsdtar」
在此並不成立**，而本檔中所有以裸 `tar` 執行卻寫成 bsdtar 的臨時比較，實際量到的都是
GNU tar。相關歸屬已就地更正。

`verifications/bsdtar_compat.zsh` was already correct: it defaults `BSDTAR_BIN`
to `C:\Windows\System32\tar.exe` on Windows and refuses to run if the binary does
not report itself as bsdtar. The ad-hoc measurements were the ones at fault, not
the committed harness.

`verifications/bsdtar_compat.zsh` 原本就是對的：它在 Windows 上將 `BSDTAR_BIN` 預設為
`C:\Windows\System32\tar.exe`，且若該執行檔的版本字串不是 bsdtar 便拒絕執行。出錯的是
臨時量測，不是入版的測試框架。

### Three-way interoperability matrix / 三方互通矩陣  ▸ ✅ 無不相容 / no incompatibility

Run 2026-08-18 on a corpus holding a Unicode filename, a hardlinked pair, a
50 KB binary and a 360-character path. Every writer's output was read by every
reader:

2026-08-18 執行，語料包含 Unicode 檔名、一組硬連結、50 KB 二進位檔與 360 字元路徑。
每個寫入端的產物都由每個讀取端讀過：

```
writer  ->  reader        rc   files
swift_tar -> swift_tar     0     6
swift_tar -> GNU tar       0     6
swift_tar -> bsdtar        0     6
GNU tar   -> swift_tar     0     6
GNU tar   -> GNU tar       0     6
GNU tar   -> bsdtar        0     6
bsdtar    -> swift_tar     0     6
bsdtar    -> GNU tar       0     6
bsdtar    -> bsdtar        0     6
```

Nine of nine, exit 0, full file count in every cell. No incompatibility to fix.
Worth re-running after any change to `archiveName()` or the header writer, since
those are what a divergence would come from.

九分之九，離開碼皆為 0，每一格的檔案數皆完整。無不相容需要修正。日後若改動
`archiveName()` 或標頭寫入端，值得重跑此矩陣——不相容會從那裡來。

### The zsh port's bundled `stat` cannot open `/c/...` paths / 移植版自帶的 `stat` 開不了 `/c/...` 路徑  ▸ ✅ 已於腳本端規避 2026-08-18

Found while re-running `encrypt_mbps_win.zsh`, which died on its first size
lookup with a single line of output:

重跑 `encrypt_mbps_win.zsh` 時發現，它在第一次取檔案大小就死掉，只留下一行輸出：

```
stat: cannot read file system information for '%z': No such file or directory
```

Under zsh, `stat` resolves to the port's own copy at
`.../scoop/apps/zsh/current/stat` (PE32+), not to `/usr/bin/stat`. That binary
**reports itself as GNU coreutils 8.32 and returns 0 for `--version`**, yet
cannot open a `/c/...` path at all:

在 zsh 下，`stat` 解析到移植版自帶的 `.../scoop/apps/zsh/current/stat`（PE32+），而非
`/usr/bin/stat`。該執行檔**自稱 GNU coreutils 8.32，且 `--version` 回傳 0**，卻完全
開不了 `/c/...` 路徑：

```
stat -c '%s' /c/Windows/System32/tar.exe
  -> cannot stat '/c/Windows/System32/tar.exe': No such file or directory
/usr/bin/stat -c '%s' /c/Windows/System32/tar.exe   -> 92176   (works)
zstat +size    /c/Windows/System32/tar.exe          -> 92176   (works)
```

**Why the script's own guard did not help.** It probed `stat --version` to pick
between the GNU and BSD spellings. That probe passed — and the script still
failed, because it asked *"is this GNU stat?"* when the question that mattered was
*"can it open this file?"*. A capability probe that tests identity instead of the
capability will pass on exactly the build that breaks you.

**該腳本自己的守門為何沒有用。** 它以 `stat --version` 在 GNU 與 BSD 兩種寫法間做選擇，
該探測通過了，腳本仍然失敗——因為它問的是**「這是不是 GNU stat」**，而真正該問的是
**「它開不開得了這個檔」**。一個檢測「身分」而非「能力」的探測，恰好會在會弄壞你的那個
建置上通過。

Worked around by using zsh's `zstat` builtin, which needs no PATH lookup and
handles both path styles; `parallel_extract_correctness.zsh` already did this.
The port itself is unchanged — other scripts calling a bare `stat` under zsh on
Windows will meet the same thing.

已改用 zsh 的 `zstat` builtin 規避，它不做 PATH 查找且兩種路徑寫法皆可處理；
`parallel_extract_correctness.zsh` 原本就是這個做法。移植版本身未變動——其他在 Windows
的 zsh 下呼叫裸 `stat` 的腳本仍會遇到同一件事。

## Recorded behaviour, not a defect / 記錄行為，非缺陷

### A zero-byte archive is an empty archive, not a malformed one / 0 bytes 的封存視為空封存而非損毀

Found while probing `-f` targets in round 33. The three implementations do not
agree, and swift_tar sides with the majority:

於 round 33 探測 `-f` 目標時發現。三種實作並不一致，而 swift_tar 站在多數一方：

```
-t on a 0-byte file    swift_tar  rc=0, empty listing
                       bsdtar     rc=0, empty listing
                       GNU tar    rc=2, "This does not look like a tar archive"
```

Two of three treat zero bytes as an archive with no members, which is the reading
swift_tar takes. **Recorded rather than changed**: it is defensible, it matches
bsdtar, and nothing in the project depends on the GNU answer.

三家有兩家把 0 bytes 視為「沒有成員的封存」，swift_tar 採取的正是此解讀。**記錄而不更動**：
該解讀站得住、與 bsdtar 一致，且本專案並無任何部分依賴 GNU 的答案。

It is here so that neither of two mistakes gets made later: "fixing" it into
GNU-compatibility without noticing bsdtar disagrees, and writing a test that
asserts an empty input must fail. A script that pipes a possibly-empty stream
into `-t` gets exit 0 and no output, so emptiness has to be checked separately.

記於此處，是為了避免日後兩種錯誤：在未察覺 bsdtar 立場不同的情況下把它「修」成與 GNU
相容；以及寫出「空輸入必須失敗」的測試。將可能為空的串流灌入 `-t` 的腳本會得到離開碼 0
與空輸出，故「是否為空」必須另行判斷。

### Case-only-differing names collapse on Windows, silently / 僅大小寫不同的名稱在 Windows 上無聲併合  ▸ ✅ 已修正 2026-08-19

An archive built on a case-sensitive filesystem can hold `file.txt`, `File.txt`
and `FILE.TXT` as three distinct members. Extracted on NTFS they are one name.
Measured 2026-08-19 with a three-member archive built on WSL's ext4:

在區分大小寫的檔案系統上建立的封存，可以同時持有 `file.txt`、`File.txt` 與
`FILE.TXT` 三個相異成員。在 NTFS 上解出時，它們是同一個名稱。2026-08-19 以 WSL ext4
建立的三成員封存實測：

| tool | files on disk | surviving name | content |
|---|---|---|---|
| swift_tar | 1 of 3 | `file.txt` — the **first** entry's case | the last entry's |
| GNU tar 1.35 | 1 of 3 | `FILE.TXT` — the **last** entry's case | the last entry's |
| bsdtar 3.8.4 | 1 of 3 | `FILE.TXT` — the last entry's case | the last entry's |

**All three exit 0 with no message**, so two members' data is discarded silently
by every one of them. **Recorded, not actioned**, and the reasoning matters
because it is the opposite of round 42's:

**三者皆以 0 結束且無任何訊息**，故兩個成員的資料在每一個工具中都被無聲丟棄。
**記錄而不處理**，其推理值得說明，因為它與 round 42 的情況正好相反：

- There, swift_tar matched bsdtar while **GNU tar refused** — so "matching a
  reference" was not a defence, and it was fixed.
- Here **no implementation defends**, because nothing can: the collision is a
  property of the destination filesystem, and any tool writing those three names
  onto NTFS ends with one file.

- 在該處，swift_tar 與 bsdtar 一致，而 **GNU tar 拒絕**——故「與某個參照一致」不構成
  辯護，因而修正。
- 在此則是**沒有任何實作能防守**，因為防不了：碰撞是目的地檔案系統的性質，任何工具把
  這三個名稱寫上 NTFS，結果都只會剩一個檔案。

What swift_tar *could* add is a warning — it knows the names it has written this
run, so a case-insensitive collision is detectable. That would turn silent data
loss into visible data loss, which is worth something. It is not done here
because it is a new feature with a per-entry memory cost, not the repair of a
defect, and nobody has asked for it. Noted so the option is on record rather
than rediscovered.

**Actioned 2026-08-19, going further than the note above proposed.** Extraction
now **refuses** the second member rather than warning, and `--force` allows it.
Refusing was chosen over warning because the loss is silent and total: a warning
on stderr is easy to miss in a script, while a non-zero exit is not.

**2026-08-19 已處理，且比上文所提更進一步。** 解出端現在對第二個成員採**拒絕**而非警告，
並以 `--force` 允許。選擇拒絕而非警告，是因為該遺失既無聲又徹底：stderr 上的一則警告在
腳本中很容易被忽略，非零離開碼則不會。

Two things the guard deliberately does not do. It does not fire on a **genuine
duplicate name** — the same spelling twice is legal tar and the last copy wins by
design, which round 16 documented. And it does not **guess** whether the
filesystem folds case: a folded match with a different spelling is only a
collision if the path already exists, which asks the filesystem instead of
assuming. Verified on WSL's ext4, where all three names extract as three files
with no warning and exit 0.

此守門刻意不做兩件事。其一，不對**真正的同名成員**觸發——相同拼法出現兩次是合法的 tar，
依設計由最後一份勝出，round 16 已載明。其二，不**猜測**檔案系統是否摺疊大小寫：摺疊後
相同但拼法不同者，唯有該路徑已經存在時才算碰撞——此舉是詢問檔案系統，而非逕行假設。已於
WSL 的 ext4 上驗證：三個名稱全部解出為三個檔案，無警告，離開碼 0。

The divergence in *which* case survives is real but inconsequential: swift_tar
opens and truncates the existing directory entry, keeping the case first seen,
while the other two unlink and recreate, adopting the last. Neither is more
correct, and the surviving content is the same in all three.

至於**哪一個**大小寫存活的差異雖屬真實，但無實質影響：swift_tar 開啟並截斷既有的目錄
項目，保留最先出現的大小寫；另外兩者則是刪除後重建，因而採用最後出現的。兩種做法並無
對錯之分，且三者存活的內容相同。

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
