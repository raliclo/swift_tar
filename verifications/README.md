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

### Results summary / 結果摘要

| Side | Pre-fix | Post-fix | Change |
| --- | --- | --- | --- |
| Encode | ~2.1–2.6GB, flat across `-n` | ~1.0–1.4GB, flat across `-n` | **−45%**, no time regression |
| Decode | ~2.5–3.0GB (ramp `n=4→12` then plateau) | ~1.2–1.4GB, flat across `-n` | **−55%**, no time regression |

The pre-fix "`n=4` decode free win" (~500MB) disappeared post-fix — it was a side effect of the leak (fewer in-flight autoreleased buffers), not a real concurrency/memory trade-off.

修正前觀察到的「decode `n=4` 免費省 500MB」在修正後消失——那是洩漏的副作用（在途 autoreleased 緩衝較少），不是真正的並行度/記憶體取捨。

### Practical takeaway / 實務結論

- No `-n` tuning needed for memory: post-fix RSS is flat across `-n` on both sides. Keep the default.
- Remaining ~1.0–1.4GB is still larger than the LZFSE formats' footprint; if further reduction matters, the next suspects are `ParallelChunkSink`'s `buffer` append/removeFirst pattern and `TarReader.pending` capacity retention — unverified.
- 記憶體層面不需要調 `-n`：修正後兩側 RSS 在各 `-n` 間都打平，維持預設即可。
- 剩餘的 ~1.0–1.4GB 仍高於 LZFSE 格式的足跡；若還要再降，下一個嫌疑對象是 `ParallelChunkSink` 的 `buffer` append/removeFirst 模式與 `TarReader.pending` 的容量保留——尚未驗證。
