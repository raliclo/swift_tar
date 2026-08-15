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

### ✅ R46-Mac(已完成 2026-08-11,swift_tar 16cd98e):POSIX 版平行寫入池 + 單次開檔

下方候選已實作為「Extract small files in parallel on macOS and Linux」,並於
R47-Mac 一輪(`-swift_tar -power-test`)完成量測:

- **llama.cpp 解壓 27/27 組全部變快,中位數 +171%**(min +50%、max +256%),
  解壓時間普遍由 9–10 秒降至 3–4 秒。
- **收益遠超原先「預期收益有限」的評估。** 原評估以「Mac 每檔固定成本 ~0.23ms」
  推論,低估了 40k 檔級距的累積效果:llama.cpp 有 41,576 檔、96% 小於 64 KB,
  正是此手法的最佳場景。claw-code(5,402 檔、71% 小檔)提升較小且波動大。
- **所有格式皆受惠,不只 TGZ**:`-swift_tar` 模式下 zshrc 中每種格式的解壓都以
  `| tar -xf -` 收尾(連 LZFSE 家族亦然),故平行小檔解出惠及全部格式。
- 正確性:新增 `verifications/parallel_extract_correctness.zsh`(10 項),涵蓋
  symlink 不被排隊寫入覆蓋、重複項目最後者勝、hardlink 共用 inode、mode 與
  mtime 保留;已納入 `run_round.command` 守門。
- 風險「動到 macOS 行為」已實現但受控:回歸 124 項全過。

### R46-Mac(原候選內容,保留供對照):POSIX 版平行寫入池 + 單次開檔

把 R45-Win 的兩個手法搬到 macOS/POSIX 分支,做成獨立一輪:

- **寫入池**:`FileWriterPool` 池化小檔寫入(平行度沿用 `-n`),目前僅 `#if os(Windows)`;POSIX 側可直接重用同一 class,只換 worker 的寫檔函式。
- **單次開檔後端**:`open(O_WRONLY|O_CREAT|O_TRUNC)` → `write` → `futimens(fd)`(同一 fd 設 mtime)→ `close`,取代現行 `createFile`+`FileHandle`+`setAttributes` 三次呼叫;`chmod` 可併入 `open` 的 mode 參數或 `fchmod(fd)`。
- **預期收益有限**:Mac 每檔固定成本 ~0.23ms(Windows 是 2–3.8ms),APFS 無 filter-driver 稅;僅對 40k+ 小檔資料集可能有感。需以 Mac 基準(R43-Mac:llama.cpp ~130 MB/s、claw-code ~500–600 MB/s)另行前後對比驗證,不可沿用 Windows 數據推論。
- **風險**:動到 macOS 行為(R45-Win 刻意零改動);需重跑 macOS self-test 與 benchmark pipeline(`run_round.command`)確認無回歸。

---

# RGB1 DOE 量測正確性計畫 / RGB1 DOE Measurement-Integrity Plan

2026-08-14 review 提出四項,加上兩項先前發現但未追蹤的次要問題。分階段處理,
順序依「是否污染已入版數據」而非依修改難度排列。
Raised in the 2026-08-14 review, plus two minor items found earlier and never
tracked. Ordered by whether an issue contaminates committed data, not by how
hard it is to fix.

詳細成因與行號見 [../rgb1/todo.md](../rgb1/todo.md) 的「Known issues」章節。
Full diagnosis and line numbers live in the "Known issues" section of
[../rgb1/todo.md](../rgb1/todo.md).

## Phase 1 — 計時正確性 / Timing integrity  ▸ ✅ 已完成 2026-08-14

**實測結果**:掃描實際使用的組合(`predictive` preset + `--no-verify`,兩個
preset 皆不含 `--delta`)修正後完全不再攤平。交錯 5 輪取 best-of:解碼由
**16.27 ms/f 降至 9.51 ms/f(−41.5%)**,遠大於原估的 5–10%——6 格 1080p 的
攤平成本疊加,且 `predictive` 解碼本身較快,比例上更顯著。單筆波動大
(9.5–26 ms),故以交錯執行取 best-of 比較。
**Measured**: with the combination the scan actually uses (`predictive` preset
plus `--no-verify`; neither scanned preset enables `--delta`), the flatten is
now skipped entirely. Interleaved best-of-5: decode fell from **16.27 to
9.51 ms/f, −41.5%**, well beyond the 5–10% estimate.

**為何優先**:A 讓 `--no-verify` 失去意義,而 budget 掃描正是靠它避開比對成本。
1080p 每格多 6.2 MB 配置加複製(約 0.5–1 ms)落在計時區內,對照解碼 ~9–10 ms
與 16.67 ms 預算,約灌水 5–10%——直接影響 PASS/FAIL 判定。
**Why first**: A defeats `--no-verify`, which the budget scan relies on to avoid
the comparison cost. The extra 6.2 MB allocation and copy per 1080p frame
(~0.5–1 ms) sits inside the timed region, inflating a ~9–10 ms decode against a
16.67 ms budget by roughly 5–10% — it moves the PASS/FAIL line itself.

- [x] **A** — `swift_tar_DOE.swift:848`:改為僅在需要時攤平
      (`--delta` 需要它作下一格參考,`--verify` 需要它作比對)。
- [x] **B** — 同段落 `:848`/`:850` 重複運算:存區域變數重用。
- [x] 驗證:`--no-verify` 與 `--verify` 兩種模式各跑一次,確認結果一致且
      `--no-verify` 的解碼時間下降;`comparison.csv` 重跑前後對比。

**注意**:`comparison.csv` 自 A 出現後尚未重跑,故目前入版數字仍乾淨;灌水會在
下次執行才發生。修完再跑,不必回溯既有資料。
**Note**: `comparison.csv` has not been regenerated since A appeared, so the
committed numbers are still clean. Fix first, then run — no back-fill needed.

## Phase 2 — 潛在崩潰 / Latent crash  ▸ ✅ 已完成 2026-08-14

- [x] **C** — 已於呼叫端（`:842` 附近）補上與 `encodeBand:620` 鏡像的尺寸守門。
      目前僅因 sampler 產出的影格尺寸一致而未爆發;DOE 接受任意檔案清單,
      尺寸混雜時編碼端跳過差分而解碼端照做 → 重建錯誤,前一格較小則越界崩潰。
- [x] 驗證:以刻意混雜尺寸的兩格語料執行 `--delta --verify`,確認不崩潰且
      要嘛正確重建、要嘛明確失敗(不得靜默產出錯誤結果)。

## Phase 3 — 量測方法論 / Measurement methodology  ▸ ✅ 已完成 2026-08-14

- [x] **#2** — 結論:**疑慮不成立,無需改動已發布數字。**
- [x] ~~更正一則先前的判斷:review 稱「這項沒有動」,實際上 `0e528ec` 已新增
      `batch_vs_per_frame.zsh` 專測此事(該 commit message 未提及,故被漏看)。~~
      **撤回:時序不支持。** `git ls-tree fd48496` 顯示該檔在該則 review 所依據的
      提交(`fd48496`,08-14 00:51)尚不存在;它由 40 分鐘後的 `0e528ec`(01:31)
      加入。後續涵蓋 `0e528ec` 的 review 已認可該腳本並自承跨格去重的假設有誤。
      Withdrawn — the timeline does not support it: the file did not exist at the
      commit that review was written against, and was added 40 minutes later.

1080p 下批次不會灌大每格位元率,因為單格 3.1 MB(NV12)/6.2 MB(RGB24)已超出
zstd、gzip、lz4 的回看視窗,它們根本無法參照前一格。兩支腳本互相印證:
`batch_vs_per_frame.zsh` 以 zstd -3 對兩種來源量得 −0.1%～0.0%;本次為
`nv12_vs_rgb1_streaming.zsh` 新增 `--batch`／`--per-frame`／`--both`,把比較延伸
到全部五種 codec。**該次延伸的結論已於 2026-08-14 推翻**:當時量測落在片頭的自黑
畫面淡入(腳本缺少 -ss),所有 codec 都壓到約 5%,差距看不出來,故記為最大 +0.34%。
改自中段取 48 格重跑後,zstd／gzip／lz4 維持在 −0.08%～+0.05%,但 **xz 對 NV12 為
+21.27%**——xz 的 8 MiB 字典大於 3.11 MB 的單格(可容納 2.70 格),視窗假說從一開始
就不適用於它。詳見 rgb1/todo.md 的 #10。

At 1080p, batching does not inflate the per-frame bitrate: a frame is larger
than zstd/gzip/lz4 can look back across, so they never reference the previous
one. Two scripts agree — `batch_vs_per_frame.zsh` at zstd -3 across two sources
(−0.1% to 0.0%), and the new `--batch`/`--per-frame`/`--both` modes here across
all five codecs. **That extension was overturned on 2026-08-14**: it had been
measured on the clip's fade-from-black opening (the script had no -ss), where
every codec compressed to ~5% and the gap was invisible, giving +0.34%. Re-run
from mid-video over 48 frames, zstd/gzip/lz4 hold at −0.08% to +0.05% but
**xz on NV12 is +21.27%** — its 8 MiB dictionary exceeds a 3.11 MB frame, so the
window hypothesis never applied to it. See rgb1/todo.md #10.

FAQ.md 已加註雙語說明並同時引用兩支腳本;若解析度低到單格能放進 codec 視窗,
須重新檢查。
FAQ.md now carries a bilingual note citing both scripts, with the caveat that a
low enough resolution would require re-checking.

## Phase 4 — 次要 / Minor  ▸ ✅ 已完成 2026-08-14

- [x] `crypto.swift`:`index` 為 `UInt32` 且以 `&+=` 遞增,理論上 2^32 chunks
      (4 MiB × 2^32 = 16 PiB 單一封存)會回繞造成 nonce 重用——對
      ChaCha20-Poly1305 是嚴重問題,但門檻實務不可達。可加上限檢查以策安全。
- [x] `test_strip_components.sh` 檔案模式為 `100644`,其餘測試皆 `100755`;
      clone 後無法直接 `./test_strip_components.sh` 執行,需 `bash` 前綴。
      `git update-index --chmod=+x` 即可。
