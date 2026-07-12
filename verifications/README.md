# verifications

Ad-hoc measurement scripts for swift_tar behavior that isn't covered by the main benchmark pipeline (`../../benchmark.sh` / `../../benchmark2.sh`). Results here are exploratory — read the "Status" line on each before trusting a conclusion.

臨時性的 swift_tar 量測腳本，涵蓋主 benchmark pipeline（`../../benchmark.sh` / `../../benchmark2.sh`）沒有測到的行為。這裡的結果屬於探索性質——採信結論前請先看每節的「狀態」。

## tgz_inflight_rss.sh

**Question**: Does swift_tar's `-n` flag (in-flight chunk concurrency for chunk-parallel gzip) control TGZ encode/decode peak RSS? `zshrc.sh`'s `getar()` never passes `-n`, so TGZ benchmark runs use the default `inflight = cores*2` (20 on the 10-core R45-Mac test machine) — this was raised while investigating why TGZ shows the highest peak RSS of any format in `OPTIMIZATION.md` (~2.5-3.3GB for a 1.3GB corpus, vs a few hundred MB for the LZFSE formats).

**問題**：swift_tar 的 `-n` 旗標（chunk-parallel gzip 的在途 chunk 並行數）是否控制 TGZ encode/decode 的 peak RSS？`zshrc.sh` 的 `getar()` 從未帶 `-n`，所以 TGZ benchmark 一律用預設值 `inflight = cores*2`（R45-Mac 測試機 10 核心 → 20）——這是在追查為何 TGZ 是 `OPTIMIZATION.md` 裡所有格式中 peak RSS 最高的（1.3GB 語料約 2.5-3.3GB，其他 LZFSE 格式只要幾百 MB）時提出的。

**Usage**:
```sh
swift_tar/verifications/tgz_inflight_rss.sh <path-to-corpus>
```

**Raw output**: [`tgz_inflight_rss_output.txt`](tgz_inflight_rss_output.txt) — always overwritten with the latest run's stdout (the script tees automatically). Sweeps run against the real `claw-code` corpus (~1.3GB) on the R45-Mac test machine.

### Root cause found & fixed (2026-07-12) / 已找到並修正根因

Pre-fix, both encode (~2.1–2.6GB) and decode (~2.5–3.0GB) peak RSS were roughly corpus-sized and insensitive to `-n` — the signature of **Foundation `FileHandle.read` autorelease accumulation** in tight CLI loops. `lzfse-cli.swift` already wrapped all its read loops in `autoreleasepool` (which is why LZFSE formats measured only a few hundred MB); `swift_tar.swift` had zero `autoreleasepool` usage.

**Fix**: wrapped the hot read/write loops in `autoreleasepool` — `TarWriter.add` file-read loop, `ParallelChunkSink.dispatch` worker, `gzipDecodeStream`, `TarReader.readExactly`, the extract write loop, and the trailing drain loop. Verified with `swift_tar -test -debug` (4/4) plus a full claw-code round-trip (`diff -rq` clean, system tar reads the output).

修正前 encode（~2.1–2.6GB）與 decode（~2.5–3.0GB）的 peak RSS 都接近語料大小且對 `-n` 不敏感——這是 Foundation `FileHandle.read` 在 CLI 緊密迴圈中 **autorelease 累積**的典型特徵。`lzfse-cli.swift` 的讀檔迴圈本來就都包了 `autoreleasepool`（所以 LZFSE 格式只有幾百 MB）；`swift_tar.swift` 則完全沒有使用。修正方式是把熱讀寫迴圈包進 `autoreleasepool`，並以 `swift_tar -test -debug`（4/4）與完整 claw-code round-trip（`diff -rq` 無差異、系統 tar 可讀）驗證。

### Root cause #2 found & fixed (2026-07-12, phase 2) / 第二個根因已找到並修正

After phase 1, RSS was still ~corpus-sized (~1.3GB). Live `heap` profiling mid-encode showed **a single ~1.06GB malloc node** — the `Data` append + `removeFirst` pattern: `removeFirst` retains the backing store while `append` keeps extending it, so one buffer grows to the size of the entire tar stream. Two sites had this pattern:

- `ParallelChunkSink.buffer` (encode): rewritten to fill a staging `Data` to exactly `chunkSize` and hand the whole object to the worker, starting a fresh buffer each chunk.
- `TarReader.pending` (decode): rewritten with an explicit consumed-offset + `subdata` compaction, so the backing store stays bounded.

Phase 1 後 RSS 仍接近語料大小（~1.3GB）。對執行中的 encode 做 `heap` 剖析，發現**單筆約 1.06GB 的 malloc 節點**——即 `Data` 的 append + `removeFirst` 模式：`removeFirst` 保留 backing store、`append` 持續延長，同一塊緩衝最終成長到整條 tar stream 的大小。兩處有此模式：`ParallelChunkSink.buffer`（encode，改為填滿 `chunkSize` 即整塊交棒、換新緩衝）與 `TarReader.pending`（decode，改為明確 offset + `subdata` 壓實）。

### macOS results summary / macOS 結果摘要

> Status: verified on the R45-Mac machine only. These numbers do **not**
> generalize to Windows; see the Windows section below.
>
> 狀態：僅在 R45-Mac 測試機確認。這組數字**不能**直接套用到
> Windows；Windows 結果請看下一節。

| Side | Pre-fix | Phase 1 (autoreleasepool) | Phase 2 (buffer patterns) |
| --- | --- | --- | --- |
| Encode | ~2.1–2.6GB, flat | ~1.0–1.4GB, flat | **90MB (`n=4`) → 300MB (`n=40`); default `n=20` = 219MB** |
| Decode | ~2.5–3.0GB | ~1.2–1.4GB, flat | **~50MB, flat across `-n`** |

No time regression at any phase (encode 4.3–7.6s, decode 2.8–3.9s throughout). Encode RSS now shows the true linear `-n` relationship (inflight × ~8MiB per chunk in flight) that the leaks previously masked.

各階段均無時間退化（encode 4.3–7.6s、decode 2.8–3.9s）。encode RSS 現在才顯現真正的 `-n` 線性關係（在途 chunk × 每塊約 8MiB），先前被洩漏遮蔽。

### Windows verification: improvement reproduced / Windows 驗證：已重現改善

Raw output: [`tgz_inflight_rss_win_output.txt`](tgz_inflight_rss_win_output.txt)

The Windows codec backend needed two additional changes because non-LZFSE
codecs run through external CLI processes there: replace per-chunk Foundation
`Thread` writers with dedicated `DispatchQueue` pipe pumps, and use synchronous
`readData(ofLength:)` reads whose `Data` lifetime is bounded by each loop
iteration. A global queue was deliberately not used because the compression
workers can saturate it while synchronously waiting for their pipe writers.

A full `-n 4..40` sweep (`tgz_inflight_rss_win.sh`, same script shape as the
macOS one, using a companion `measure_peak_ws_win.ps1` since Windows has no
`/usr/bin/time -l`) on the same `claw-code` corpus confirms the bounded-memory
behavior across the whole range, not just the three sampled points:

| `-n` | Encode peak WS | Decode peak WS |
| --- | ---: | ---: |
| 4 | 58.6MB | 36.6MB |
| 8 | 84.0MB | 36.8MB |
| 12 | 115.6MB | 36.7MB |
| 16 | 137.8MB | 37.3MB |
| 20 | 162.7MB | 35.1MB |
| 24 | 180.9MB | 36.7MB |
| 28 | 206.1MB | 36.4MB |
| 32 | 222.3MB | 36.5MB |
| 36 | 243.1MB | 36.8MB |
| 40 | 268.7MB | 37.2MB |

Before this Windows-specific fix, encode used **2.5–2.7GB** and decode used
**2.50–2.55GB**. Encode now exposes the expected linear `-n` relationship
(same shape as macOS), while decode stays flat around 36–37MB regardless of
`-n`.

⚠ **Wall-clock time is a separate axis from RSS and remains far behind macOS**:
this same sweep measured encode at 27–47s and decode at 17–19s for the 1.4GB
corpus, vs macOS's 4.3–7.6s / 2.8–3.9s (see `tgz_inflight_rss_output.txt`).
The `DispatchQueue` fix above resolved the *memory* regression, not the
*speed* gap — the per-chunk external `gzip.exe` process spawn (Windows has no
bundled zlib, see main `OPTIMIZATION.md`) is the dominant remaining cost and
is architectural, not a bug.

Windows codec backend 因為透過外部 CLI 程序執行非 LZFSE codec，需要另外兩項
修正：將每個 chunk 的 Foundation `Thread` writer 改成專用 `DispatchQueue`
pipe pump，並改用同步 `readData(ofLength:)`，讓每輪 `Data` 的生命週期有明確
上限。這裡刻意不使用 global queue，避免壓縮 worker 佔滿 queue、又同步等待
pipe writer 而造成飢餓死鎖。

同一份 `claw-code` 語料跑完整的 `-n 4..40` 掃描（`tgz_inflight_rss_win.sh`，
腳本結構跟 macOS 版相同，Windows 沒有 `/usr/bin/time -l`，改用旁邊的
`measure_peak_ws_win.ps1` 輔助腳本量測），確認整個範圍都重現了有界記憶體
行為，不只是 3 個抽樣點：

| `-n` | Encode peak WS | Decode peak WS |
| --- | ---: | ---: |
| 4 | 58.6MB | 36.6MB |
| 8 | 84.0MB | 36.8MB |
| 12 | 115.6MB | 36.7MB |
| 16 | 137.8MB | 37.3MB |
| 20 | 162.7MB | 35.1MB |
| 24 | 180.9MB | 36.7MB |
| 28 | 206.1MB | 36.4MB |
| 32 | 222.3MB | 36.5MB |
| 36 | 243.1MB | 36.8MB |
| 40 | 268.7MB | 37.2MB |

修正前 Windows encode 為 **2.5–2.7GB**、decode 為 **2.50–2.55GB**；修正後
encode 呈現跟 macOS 相同形狀的線性 `-n` 關係，decode 則不分 `-n` 打平在
約 36–37MB。

⚠ **時間跟 RSS 是兩條不同的軸線，時間目前仍遠落後 macOS**：同一次掃描量到
1.4GB 語料的 encode 27–47 秒、decode 17–19 秒，對照 macOS 的 4.3–7.6 秒／
2.8–3.9 秒（見 `tgz_inflight_rss_output.txt`）。上面的 `DispatchQueue`
修正解決的是**記憶體**退步，不是**速度**落差——每個 chunk 各自 spawn 一次
外部 `gzip.exe` process（Windows 沒有可連結的 zlib，詳見主文件
`OPTIMIZATION.md`）才是剩下的主要成本，這是架構性的，不是 bug。

### Practical takeaway / 實務結論

- On macOS, TGZ memory footprint is now comparable to (or below) the LZFSE formats. Default `-n` needs no tuning; lower `-n` still trades encode speed for memory if ever needed (`n=4` = 90MB at +75% time).
- On Windows, the dedicated pipe queues and bounded synchronous reads reduce TGZ encode RSS to 59–269MB (`-n 4–40`, linear) and decode RSS to about 35–37MB flat.
- Windows TGZ wall-clock time is still 4–6x slower than macOS (27–47s vs 4.3–7.6s encode; 17–19s vs 2.8–3.9s decode) — this is the per-chunk external `gzip.exe` process cost, a separate architectural gap from the RSS fix, not something this fix addresses.
- Correctness verified: the current `swift_tar -test -debug` passed all 6 checks, including both Windows write backends and bidirectional system-tar interoperability.
- 在 macOS 上，TGZ 的記憶體足跡現在已與 LZFSE 格式相當（甚至更低）。預設 `-n` 不需調整；真有需要時，調低 `-n` 仍可用 encode 時間換記憶體（`n=4` = 90MB，時間 +75%）。
- 在 Windows 上，專用 pipe queue 與有界同步讀取將 TGZ encode RSS 降至 59–269MB（`-n 4–40`，線性），decode RSS 降至約 35–37MB 打平。
- Windows TGZ 的時間仍比 macOS 慢 4–6 倍（encode 27–47 秒 vs 4.3–7.6 秒；decode 17–19 秒 vs 2.8–3.9 秒）——這是每個 chunk 各自 spawn 外部 `gzip.exe` process 的成本，跟這次 RSS 修正是不同的架構性落差，這次修正沒有解決這個問題。
- 正確性驗證完成：目前的 `swift_tar -test -debug` 六項檢查全數通過，包含兩種 Windows 寫入後端與系統 tar 雙向互通。
