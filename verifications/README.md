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

**Raw output**: [`tgz_inflight_rss_output.txt`](tgz_inflight_rss_output.txt) — full sweep (`n=4..40 step 4`) run against the real `claw-code` corpus (~1.3GB) on the R45-Mac test machine.

### Results summary / 結果摘要

| Side | Status | Finding |
| --- | --- | --- |
| Encode | ❌ Unconfirmed / 未確認 | RSS is flat ~2.1–2.6GB across every `-n` from 4 to 40, no monotonic trend with concurrency. `-n` does not appear to be the primary driver of encode-side peak RSS in this sweep. |
| Decode | ✅ Consistent shape / 形狀一致 | RSS ramps from `n=4` (~2.5GB) up through roughly `n=12` (~3.0GB), then plateaus through `n=40`. `n=4` saves ~500MB–1GB versus the `n≥12` plateau, with no consistent time penalty (2.6–4.0s across all `n`, no pattern tied to `-n`). |

### Practical takeaway / 實務結論

- **Decode**: passing `-n 4` when extracting a `.tgz` via swift_tar is a low-risk, reproducible way to cut peak RSS by ~500MB–1GB with no observed time cost. Nothing in the pipeline currently sets this (`zshrc.sh` extract paths don't pass `-n` either).
- **Encode**: no actionable recommendation yet — this sweep shows no relationship between `-n` and peak RSS, so lowering `-n` in `getar()` would not be expected to help. Before drawing further conclusions, rerun with a controlled disk-cache state (e.g. `purge` between runs, or run each `-n` multiple times and take the median) and investigate what else could be driving encode-side memory.
- decode：用 swift_tar 解壓 `.tgz` 時帶 `-n 4`，風險低且可重現地省下約 500MB–1GB peak RSS，沒有觀察到時間代價。目前 pipeline（`zshrc.sh` 的解壓路徑）都沒有帶這個旗標。
- encode：目前沒有可行動的結論——本次掃描顯示 `-n` 與 peak RSS 無關，調低 `getar()` 的 `-n` 預期不會有幫助。要進一步下結論前，應在控制磁碟快取狀態下重跑（例如兩輪之間 `purge`，或每個 `-n` 跑多次取中位數），並查明 encode 端記憶體真正的驅動因子。
