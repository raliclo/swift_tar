# Cross-platform verification flow / 跨平台驗證流程

Two machines work on this repository at once — macOS here, Windows there — and
both have run blind documentation tests and fixed defects independently. Twice
now that has produced avoidable damage: a fix verified only on Windows took ZIP
out entirely on macOS, and a rebase of parallel README edits nearly duplicated
two whole sections. This file exists so the order of operations is written down
rather than re-derived each time.

本程式庫同時有兩台機器在作業——此處是 macOS，另一端是 Windows——雙方都各自跑過盲測
並修過缺陷。至今已有兩次因此造成本可避免的損害：一個僅在 Windows 驗證過的修正讓
macOS 的 ZIP 完全失效；而平行的 README 編輯在 rebase 時幾乎複製了整整兩個章節。本檔
的存在，是為了把操作順序寫下來，而不是每次重新推導。

## The rule / 規則

**Gather every platform's evidence first. Change the code once, at the end.**

**先收齊所有平台的證據，最後才一次改完程式碼。**

Not because batching is tidier, but because a change made after seeing one
platform is a change made in ignorance of the other three. The ZIP outage is the
worked example: `hdrcharset=UTF-8` was correct for Windows, fatal for macOS, and
nobody could have known that from the Windows machine alone.

這麼做不是因為批次比較整齊，而是因為「只看過一個平台就動手」等於在對其餘三個平台
一無所知的情況下修改。ZIP 停擺就是現成的例子：`hdrcharset=UTF-8` 對 Windows 是正確的、
對 macOS 是致命的，而單憑 Windows 那台機器不可能得知這件事。

## The four phases / 四個階段

### Phase 1 — build and measure, in parallel, changing nothing
### 階段一 — 平行建置與量測，不改任何東西

On each platform: build, then run the suites. Record the results. **Do not fix
anything yet**, however obvious the fix looks — that is the phase whose whole
purpose is to be ignorant of the answer.

| Platform | Build | Interop matrix | Reference tars expected |
|---|---|---|---|
| macOS | `./build.zsh` | `verifications/tar_interop_matrix.zsh` | bsdtar (`/usr/bin/tar`), GNU tar (`gtar`, from `brew install gnu-tar`) |
| Windows / MSYS | `./build.zsh` | same | bsdtar (`C:\Windows\System32\tar.exe`), GNU tar (MSYS `tar`) |
| Linux VM on macOS | `~/projWin/VM-test/run.sh` | same, inside the guest | GNU tar; bsdtar only if installed |
| WSL | via multissh | same | GNU tar; bsdtar only if installed |

The matrix identifies each reference by what it says about itself, never by
filename: `tar` is bsdtar on macOS, GNU tar on most Linux, and on Windows
`tar.exe` is bsdtar while the MSYS `tar` is GNU. Keying on filenames mislabels
every row.

矩陣以各參照工具的自我描述辨識，絕不以檔名判斷：`tar` 在 macOS 是 bsdtar、在多數
Linux 是 GNU tar，而 Windows 的 `tar.exe` 是 bsdtar、MSYS 的 `tar` 則是 GNU。
以檔名為鍵會把每一列都標錯。

Parallelism is real but bounded: background agents and background builds run
concurrently, and independent tool calls in one message run concurrently. What
cannot overlap is two lines of work editing the same tree.

可平行的部分是真的，但有界線：背景 agent、背景建置、以及單一訊息內的獨立呼叫都能
並發。無法重疊的是「兩條線編輯同一個工作樹」。

### Phase 2 — consolidate the requirements before writing anything
### 階段二 — 動手之前，先彙整需求

Put every platform's failures in one place and ask of each: is this a defect, or
is it that platform's convention? The two are fixed differently and the answer is
rarely visible from one machine.

Worked example, from this repository: the matrix first reported "swift_tar
cannot read bsdtar's archives" on macOS. It was not a defect. macOS bsdtar writes
an AppleDouble `._name` member beside every entry to carry extended attributes,
hides them again on its own read, and folds them back into xattrs. GNU tar lists
them, extracts them as ordinary files, and warns about the unknown header — and
swift_tar does exactly what GNU tar does. The finding was real; the diagnosis
"swift_tar is broken" was wrong. Confirmed by reading the raw tar headers, with
no tar involved at all.

把各平台的失敗集中起來，逐項自問：這是缺陷，還是該平台的慣例？兩者的修法不同，而
答案很少能從單一機器看出來。

實例：矩陣起初在 macOS 回報「swift_tar 讀不懂 bsdtar 的封存」。那不是缺陷。macOS 的
bsdtar 會為每個項目寫入 AppleDouble `._名稱` 成員以攜帶延伸屬性，並在自己讀取時隱藏、
解出時還原為 xattr。GNU tar 會列出它們、解為一般檔案並警告該標頭無法辨識——而
swift_tar 的行為與 GNU tar 完全相同。發現本身是真的，「swift_tar 壞了」這個診斷是錯的。
最終以直接讀取原始 tar 標頭確認，全程不經任何 tar。

**When a platform disagrees with the others, name which one is the outlier
before deciding who is wrong.**
**當某個平台與其他不同時，先指出誰是離群者，再決定誰錯了。**

### Phase 3 — one change, addressing all platforms at once
### 階段三 — 一次改完，同時涵蓋所有平台

Write the fix knowing every platform's constraint. A fix that helps one platform
must be checked against the mechanism the others rely on — the ZIP fix kept
Windows's `hdrcharset` path untouched and added a second, separate mechanism for
the platforms where that option cannot work.

Also: a fix in one direction is not a fix. Setting the UTF-8 flag on write alone
produced archives that bsdtar and Python read correctly and swift_tar itself
could not open. Both directions, or neither.

在知悉所有平台限制的前提下寫出修正。對某一平台有幫助的修正，必須對照其他平台所依賴的
機制檢查——ZIP 的修正完整保留了 Windows 的 `hdrcharset` 路徑，另外為該選項無法運作的
平台加上第二套獨立機制。

另外：只修一個方向不算修好。只在寫入端設定 UTF-8 旗標，產出的封存 bsdtar 與 Python
讀得正確，swift_tar 自己卻打不開。要嘛兩個方向都做，要嘛都不做。

### Phase 4 — re-verify everywhere, then record
### 階段四 — 各平台重新驗證，然後才記錄

Re-run Phase 1 on every platform against the changed build. Only a fully passing
run may write a record — `--record` is opt-in on the scripts that write to
`verifications/`, because a correctness run that silently overwrites a
measurement leaves a record nobody chose to take.

以更動後的建置在每個平台重跑階段一。唯有全數通過的執行才可寫入紀錄——會寫入
`verifications/` 的腳本一律以 `--record` 選擇性加入，因為一次靜默覆寫量測的正確性執行，
留下的是一份沒有人決定過要取得的紀錄。

## Where things are recorded / 各類事項記錄於何處

| Kind | Goes in |
|---|---|
| How to use a feature | `README.md` + `README.zh-TW.md`, both, kept symmetric |
| A defect, or an incompatibility with another tool | `todo/todo.md` — **not** the README |
| A measurement | `verifications/*_output-<platform>.txt`, written only with `--record` |
| A regression test for a fixed defect | `test_blind_findings.zsh` |

Defect narratives were moved out of the READMEs deliberately: a README that
catalogues its own bugs teaches the reader to distrust the parts that are fine.

缺陷敘述是刻意移出 README 的：一份羅列自身缺陷的 README，會教讀者連正確的部分也不要
相信。

## Standing rules that keep biting / 一再重演、故列為常規

- **Verify the agent, not just the code.** A blind tester has been wrong about
  its own findings four times in seven rounds — "input is stdin only" (a
  positional path works), "`-f` has two directions" (it has three), "there is no
  timezone flag" (`--tz-offset-min`), "480 may be the host timezone" (it is a
  constant). Every one would have gone into the README verbatim.
  **驗證的對象包含 agent，不只是程式碼。** 盲測者在七回合中有四次對自己的發現判斷
  錯誤，每一項若照抄都會逐字寫進 README。
- **A test that cannot fail proves nothing.** Run the new test against the
  unfixed binary before believing it.
  **不會失敗的測試什麼也證明不了。** 相信一個新測試之前，先拿未修正的執行檔跑一次。
- **`.sh` → `.zsh` renames drop the exec bit.** Eleven committed scripts became
  non-executable that way; two test suites failed with 126 as a result.
  **`.sh` → `.zsh` 改名會掉執行位元。** 曾有十一支入版腳本因此無法執行。
- **Check `git status` after a suite run.** Scripts that write records will
  otherwise commit a measurement taken under machine load — one such table came
  in with every time uniformly 8% slower and the sizes unchanged.
  **跑完測試後檢查 `git status`。** 否則會把機器負載下取得的量測提交進去。
