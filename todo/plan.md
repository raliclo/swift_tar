# swift_tar Windows 解壓效能改善計畫 / Windows Extraction Performance Plan

## Context 背景與診斷

Windows 上 swift_tar 解壓遠慢於 macOS。三個問題的結論:

1. **解壓有 streaming。** 各 codec 以 1 MiB chunk 串流(swift_tar.swift:620-872);tar 層 `TarReader.run`(:1763)逐段讀寫;LZFSE 快速路徑為滑動視窗串流(lzfse-cli.swift:3184)。唯一例外是 LZFSE fallback(stdin/巢狀時整檔載入 :1162),非瓶頸。
2. **瓶頸是每檔固定成本,不是防毒、也不是寫入吞吐。** 關鍵對照(同機、同防毒、同資料集):
   - R42-Win(bsdtar)decode:claw-code 146–209 MB/s、llama.cpp 21.5–30.6 MB/s
   - R43-Win(swift_tar)decode:claw-code 37–69 MB/s、llama.cpp 8.2–10.7 MB/s → **swift_tar 比 bsdtar 慢 2.2–3.5 倍,防毒兩者都在跑**
   - 每檔成本(llama.cpp,40,675 檔):bsdtar ~1.4ms、swift_tar ~3.8ms、Mac 上 swift_tar ~0.23ms
   - R43-Win §4 微基準(OPTIMIZATION.md:641-656)已證實:單一大檔 FileHandle.write ~1100 MB/s;逐檔 3 次開檔(createFile+FileHandle+setAttributes)+4–5 次 API 往返 = ~2ms/檔;**目錄快取實測僅 ~2%**。
3. **Mac 快的原因分兩層:** (a) swift_tar 自身多餘開檔(可修,本計畫目標);(b) NTFS+filter driver 平台稅(bsdtar 也承受,llama.cpp 上仍比 Mac 慢 ~6 倍)——使用者將移除防毒實測,歸因這一層。

bsdtar(libarchive)每檔只開 1 次:開檔→寫入→同 handle 設時間→關閉。swift_tar 要追平此 syscall 輪廓。

## 硬性限制 / Hard constraints

- **不得 `import WinSDK`**(R44-Win 已刻意移除,OPTIMIZATION.md:671)。允許 `import ucrt`(CRT 層,非 WinSDK;先例:lzfse-ui-win.swift:28)。
- hardlink 維持 `fsutil hardlink create`(R44 已驗證 `FileManager.linkItem` 會靜默建 symlink)。
- macOS 行為零改動(改動全包 `#if os(Windows)`)。
- 註解中英雙語;Swift 5 語言模式,沿用 `@unchecked Sendable` idiom(勿用 actor)。
- 併發 idiom 仿現有 `ParallelChunkSink`(swift_tar.swift:1196-1277):concurrent DispatchQueue + DispatchGroup + DispatchSemaphore 反壓 + NSLock 保護 first-failure State。

## 使用者決策 / User decisions

- **兩種寫檔後端都做,以旗標切換**:`-write_ucrt` 與 `-write_foundation`;self-test 內建兩者的正確性+速度對比;**依實測結果再定預設值**(定案前暫以 foundation 為預設,行為最接近現狀)。

## 改動檔案

- `C:\Users\lowei\proj\lzfse2\swift_tar\swift_tar.swift`(唯一程式碼改動;建置腳本不動,`import ucrt` 不需 linker flag)

## Step 0 — 基準量測(改碼前)

```powershell
cd C:\Users\lowei\proj\lzfse2
.\swift_tar\release\swift_tar.exe -c -f llama.cpp.tar llama.cpp   # 純 tar,隔離解碼因素
$out="C:\Users\lowei\proj\lzfse2\bench_out"
Remove-Item -Recurse -Force $out -EA SilentlyContinue; mkdir $out | Out-Null
(Measure-Command { .\swift_tar\release\swift_tar.exe -x -f llama.cpp.tar -C $out }).TotalSeconds
```
每組 3 次取中位數(每次全新目的目錄):`llama.cpp.tar`、`llama.cpp.lzfse.other3`、`claw-code.lzfse.other3`(皆原生解碼,不依賴 scoop 工具)。**防毒開/關各一組**。記錄解壓樹指紋:檔案數、總 bytes、抽 5 檔 `Get-FileHash`、5 檔 `LastWriteTimeUtc`。

## Step 1(主力)— 平行小檔寫入池 `FileWriterPool` + 雙寫檔後端

### 1a. 寫檔後端(worker 內執行)

```swift
enum WriteBackend { case foundation, ucrt }   // -write_foundation / -write_ucrt
```
- **foundation**:`data.write(to: URL(fileURLWithPath: dest), options: [])`(非 atomic,單次開檔完成 create+write+close)→ `setAttributes([.modificationDate:…])` 設 mtime(第 2 次開檔)。每檔 2 次開檔(現狀 3 次)。
- **ucrt**:`import ucrt`(swift_tar.swift:45 附近,`#if os(Windows)`)。`_wsopen`(`_O_WRONLY|_O_CREAT|_O_TRUNC|_O_BINARY|_O_SEQUENTIAL`, `_SH_DENYNO`)→ `_write` 迴圈 → `_futime64`(同一 fd 設 mtime,`__utimbuf64`)→ `_close`。**每檔 1 次開檔,syscall 輪廓同 bsdtar**。注意:確認 ucrt Swift module 是否露出 `_wsopen`/`_futime64`/`__utimbuf64`,缺的用 `@_silgen_name` 補(本 codebase 大量先例,:64-81)。

### 1b. Pool(`#if os(Windows)`,仿 ParallelChunkSink)

- `DispatchQueue(concurrent)` + `DispatchGroup` + `DispatchSemaphore(value: max(2, inflight))` 反壓;NSLock 保護 `State.failure`(first-failure-wins,producer 每次 submit 前與 join 時檢查)。
- 記憶體上限自然成立:inflight × 4 MiB 小檔上限(`-n` 預設 cores×2;`-n 40` 時 160 MiB,若 RSS 敏感可 cap min(inflight,16))。
- `smallFileMax = 4 << 20`;>4 MiB 大檔維持現行 inline 串流(吞吐 ~1100 MB/s 已足)。

### 1c. 接線

- `TarReader.Options`(:1757)加 `inflight: Int = 1` 與 `writeBackend`;`runRead`(:2428)傳入既有 `inflight`(:2444 建構處);CLI 解析加 `-write_ucrt`/`-write_foundation`(:2350 附近旗標區)。
- `TarReader.run` 一般檔案分支(:1916-1942)Windows 側:小檔 `readExactly(Int(size))` → `pool.submit(dest:data:mtime:)`;大檔走原路。padding skip(:1936)留在 parser 執行緒。verbose `print("x \(name)")`(:1869)在 submit 前,順序不變。

### 1d. 順序屏障(正確性關鍵,code review 重點)

- **hardlink('1' :1906)前 `pool.drain()`**——連結目標可能仍在佇列(hardlink 稀少,屏障便宜)。
- **重複路徑**:parser 執行緒維護已 submit 的 `Set<String>`;同名再現(tar 後者覆蓋語意)或 symlink/hardlink `removeItem` 前先 `drain()`。
- **解析迴圈後(:1947)、dirTimes 修正(:1953)前**:`pool.drain()` + 檢查 failure(寫檔會碰父目錄 mtime,必須先完成)。

## Step 2 — self-test 加入雙後端對比

`runSelfTest`(:2160 附近)擴充:同一測試樹分別以兩種後端解壓 → 內容逐檔比對一致(互相 + 對標準 tar)→ 各自計時輸出(沿用 `check()`/✓/✗ 風格),供使用者決定預設值。正式的預設值切換是後續一行改動。

## Step 3(選配,~2% 而已)— 目錄快取

R43-Win §4 已實測僅 ~2%。Step 1 驗證通過後可順手加 5 行(parser 執行緒 `Set<String>` 圍住 :1885-1888),或直接略過。

## 明確不做

- WinSDK 任何直接呼叫(含 CreateFileW/SetFileTime/CreateHardLinkW)。
- hardlink 改 API(維持 fsutil)、symlink 改動(維持 FileManager.createSymbolicLink)。
- Windows codec 改連 C 庫(decode-to-null 已 700+ MB/s)、LZFSE fallback 路徑。
- macOS 側任何行為變更。

## 驗證 / Verification(每步之後)

1. 重建 `swift_tar\compile_tar-win.bat`;**確認 exe mtime 有更新**(R44 曾因舊 binary 白查 — OPTIMIZATION.md:673)。
2. 正確性閘門(依序):
   - `release\swift_tar.exe -test`(對 System32\tar.exe 雙向 round-trip + 內容比對;含新的雙後端對比)。
   - 解壓 `llama.cpp.tar` 全新目錄,對 Step 0 指紋(數量、bytes、5 hash、5 mtime)。
   - CJK 檔名 + >260 字元路徑 round-trip(驗證 Foundation/ucrt 的長路徑處理,勿假設)。
   - hardlink 封存 round-trip(`fsutil hardlink list` 兩名並列)——驗證 drain 屏障。
   - 重複 entry 封存(同路徑兩次、不同內容):後者內容勝出。
3. 效能矩陣:{llama.cpp.tar, llama.cpp.lzfse.other3, claw-code.lzfse.other3} × {防毒開, 關} × {foundation, ucrt} × 3 次中位數;Step 1 後掃一次 `-n` ∈ {4,8,16,32,40} 找拐點。結果補入 `helper_windows/bench_results_csv/BenchMarkResult-Win.csv` 既有格式,最終寫成 OPTIMIZATION.md 新的 R45-Win 章節(雙語)。
4. 目標:llama.cpp 由 8–11 MB/s 至少追平 bsdtar(21.5+ MB/s),池化後預期 60–100+ MB/s;claw-code 由 59–69 邁向數百。

## 風險

- 池順序性(hardlink 目標未落地、重複路徑覆蓋)→ drain 屏障,review 重點。
- worker 錯誤延遲回報(first-failure-wins)→ 與既有 create 側 sink 同策略。
- ucrt module 符號露出不全 → `@_silgen_name` 補宣告(既有先例)。
- Foundation 多執行緒寫不同路徑為文件支援之用法;workers 不碰 parser 共享狀態(僅鎖內 State)。
- 若 ucrt 實測反而慢(呼應使用者對低階 API 的疑慮),self-test 對比會直接顯示,預設值選 foundation 即可——兩後端都保留。

---

## 執行結果 / Outcome(2026-07-10,詳見 OPTIMIZATION.md R45-Win)

- 預設後端定案:**ucrt**(實測比 foundation 快 25–35%)。
- llama.cpp.tar:105.0s → 33.2s(**3.2×**,36.5 MB/s,已超越 bsdtar 的 21.5–30.6 MB/s)。
- claw-code.lzfse.other3:18.1s → 8.3s(**2.2×**,168 MB/s,超越 bsdtar 的 152 MB/s)。
- 正確性:self-test 6/6、閘門 15/15(含 >260 字元長路徑——ucrt 後端曾在此失敗,已以 `winUcrtPath()` 修正)。
- `-n` 掃描持平(4–40 差距 <9%),預設 2×cores 即可。
- 解壓串流分塊已依使用者要求調升為 4 MiB(`DECODE_CHUNK`)。

---

## 候選後續 / Follow-up candidates

### R46-Mac(候選):POSIX 版平行寫入池 + 單次開檔

把 R45-Win 的兩個手法搬到 macOS/POSIX 分支,做成獨立一輪:

- **寫入池**:`FileWriterPool` 池化小檔寫入(平行度沿用 `-n`),目前僅 `#if os(Windows)`;POSIX 側可直接重用同一 class,只換 worker 的寫檔函式。
- **單次開檔後端**:`open(O_WRONLY|O_CREAT|O_TRUNC)` → `write` → `futimens(fd)`(同一 fd 設 mtime)→ `close`,取代現行 `createFile`+`FileHandle`+`setAttributes` 三次呼叫;`chmod` 可併入 `open` 的 mode 參數或 `fchmod(fd)`。
- **預期收益有限**:Mac 每檔固定成本 ~0.23ms(Windows 是 2–3.8ms),APFS 無 filter-driver 稅;僅對 40k+ 小檔資料集可能有感。需以 Mac 基準(R43-Mac:llama.cpp ~130 MB/s、claw-code ~500–600 MB/s)另行前後對比驗證,不可沿用 Windows 數據推論。
- **風險**:動到 macOS 行為(R45-Win 刻意零改動);需重跑 macOS self-test 與 benchmark pipeline(`run_round.command`)確認無回歸。
