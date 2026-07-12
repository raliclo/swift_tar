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

### Windows verification: improvement not reproduced / Windows 驗證：未重現改善

Raw output: [`tgz_inflight_rss_win_output.txt`](tgz_inflight_rss_win_output.txt)

The Windows counterpart currently does **not** reproduce the macOS RSS
improvement. On the same `claw-code` corpus, peak working set remains roughly
corpus-sized for most encode runs and for all decode runs:

| Side | Latest Windows observation |
| --- | --- |
| Encode | mostly **2.5–2.7GB** across `-n`; one `-n 40` sample reported **1.09GB**, but this is not the stable linear `-n` behavior seen on macOS |
| Decode | **2.50–2.55GB** across all tested `-n` values |

Therefore, the `219MB encode / ~50MB decode` result should be read as a
macOS-only verification result for now. Windows still needs a separate root
cause analysis; likely candidates include platform-specific buffering behavior,
Foundation `Data`/`FileHandle` behavior on Windows, or the measurement path
still catching retained process memory that the macOS `/usr/bin/time -l`
measurement does not.

Windows 對照測試目前**沒有**重現 macOS RSS 改善。同一份 `claw-code`
語料下，peak working set 在大多數 encode 測試與全部 decode 測試中仍接近語料大小：

| 方向 | 最新 Windows 觀察 |
| --- | --- |
| Encode | 多數 `-n` 仍為 **2.5–2.7GB**；只有一次 `-n 40` 樣本降到 **1.09GB**，但這不是 macOS 上看到的穩定 `-n` 線性關係 |
| Decode | 全部測試的 `-n` 都維持在 **2.50–2.55GB** |

因此，`encode 219MB / decode ~50MB` 目前只能視為 macOS 驗證結果。
Windows 仍需另外追根因；候選方向包括平台特定 buffering、Windows 上
Foundation `Data`/`FileHandle` 行為，或 Windows 量測路徑仍捕捉到 macOS
`/usr/bin/time -l` 不會計入的 retained process memory。

### Practical takeaway / 實務結論

- On macOS, TGZ memory footprint is now comparable to (or below) the LZFSE formats. Default `-n` needs no tuning; lower `-n` still trades encode speed for memory if ever needed (`n=4` = 90MB at +75% time).
- On Windows, TGZ RSS remains unresolved; do not cite the macOS `219MB / ~50MB` numbers as Windows results.
- Correctness verified at each phase: `swift_tar -test -debug` 4/4, full claw-code round-trip `diff -rq` clean, system tar reads the output.
- 在 macOS 上，TGZ 的記憶體足跡現在已與 LZFSE 格式相當（甚至更低）。預設 `-n` 不需調整；真有需要時，調低 `-n` 仍可用 encode 時間換記憶體（`n=4` = 90MB，時間 +75%）。
- 在 Windows 上，TGZ RSS 問題尚未解決；不要把 macOS 的 `219MB / ~50MB` 數字引用為 Windows 結果。
- 每階段均驗證正確性：`swift_tar -test -debug` 4/4、完整 claw-code round-trip `diff -rq` 無差異、系統 tar 可讀輸出。
